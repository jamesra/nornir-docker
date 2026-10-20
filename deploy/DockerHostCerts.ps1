<#
.SYNOPSIS
  TLS certificate helpers for stack.ps1: validate/install a PEM pair, report status, reload, push.

.DESCRIPTION
  Every TLS service reads /certs/<TLS_CERT_NAME>/{fullchain,privkey}.pem from a read-only bind
  mount of <root>/Certs. These helpers own that folder for the `manual` mode (a certificate you
  obtained yourself, e.g. an InCommon/Sectigo cert from Pitt IT) and for distributing the files
  to other hosts. Automatic modes (letsencrypt, acme-eab) are written by the viking-certs renewer
  into the same layout.

  Files written per certificate:
    cert.pem       leaf certificate
    chain.pem      intermediates (may be empty when the issuer bundles none)
    fullchain.pem  leaf + intermediates (what nginx/Kestrel/Python load)
    privkey.pem    unencrypted private key (PEM)
    cert.pfx       PKCS#12 with key + chain, for IIS (password: -PfxPassword or TLS_PFX_PASSWORD; may be empty)
    .renewed-at    ISO-8601 UTC timestamp of the last install/renewal

  Uses .NET X509 APIs (PowerShell 7 / .NET 8), so it works the same on Windows and Ubuntu
  without openssl.
#>

function Split-PemCertificates {
    <#
    .SYNOPSIS
      Return each -----BEGIN CERTIFICATE----- block in a PEM text, in order.
    #>
    param([string]$Text)
    $ms = [regex]::Matches($Text, '-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----')
    return , @($ms | ForEach-Object { $_.Value })
}

function Get-CertificateDnsNames {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($ext in $Cert.Extensions) {
        if ($ext.Oid.Value -eq '2.5.29.17') {
            $san = [System.Security.Cryptography.X509Certificates.X509SubjectAlternativeNameExtension]::new($ext.RawData, $ext.Critical)
            foreach ($n in $san.EnumerateDnsNames()) { $names.Add($n.ToLowerInvariant()) }
        }
    }
    return , $names.ToArray()
}

function Test-CertificateCoversHost {
    <#
    .SYNOPSIS
      True when a SAN entry matches the hostname exactly or as a single-label wildcard.
    #>
    param([string[]]$DnsNames, [string]$Hostname)
    $h = $Hostname.ToLowerInvariant().TrimEnd('.')
    foreach ($n in $DnsNames) {
        if ($n -eq $h) { return $true }
        if ($n.StartsWith('*.')) {
            $suffix = $n.Substring(1)  # ".example.org"
            if ($h.EndsWith($suffix) -and ($h.Substring(0, $h.Length - $suffix.Length) -notmatch '\.')) { return $true }
        }
    }
    return $false
}

function Test-DockerHostCertificate {
    <#
    .SYNOPSIS
      Report the installed certificate: presence, key match, validity window, hostname coverage.

    .OUTPUTS
      Objects with Status (OK/WARN/FAIL/INFO) and Message.
    #>
    param(
        [Parameter(Mandatory)][string]$CertsDir,
        [string]$CertName,
        [string[]]$Hostnames = @()
    )
    $results = [System.Collections.Generic.List[object]]::new()
    function Add-R([string]$s, [string]$m) { $results.Add([pscustomobject]@{ Status = $s; Message = $m }) }
    if (-not $CertName) { Add-R FAIL 'TLS_CERT_NAME is not set (host.env)'; return , $results.ToArray() }
    $dir = Join-Path $CertsDir $CertName
    $full = Join-Path $dir 'fullchain.pem'
    $key = Join-Path $dir 'privkey.pem'
    if (-not (Test-Path -LiteralPath $full) -or -not (Test-Path -LiteralPath $key)) {
        Add-R FAIL "no certificate at $dir (stack.ps1 certs letsencrypt | acme-eab | manual)"
        return , $results.ToArray()
    }
    try {
        $x = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($full, $key)
    }
    catch {
        Add-R FAIL "fullchain.pem/privkey.pem do not load as a matching pair: $($_.Exception.Message)"
        return , $results.ToArray()
    }
    $days = [int][Math]::Floor(($x.NotAfter.ToUniversalTime() - [DateTime]::UtcNow).TotalDays)
    $issuer = $x.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)
    $msg = "cert $CertName issued by '$issuer', expires $($x.NotAfter.ToString('yyyy-MM-dd')) ($days days)"
    if ($days -lt 0) { Add-R FAIL "$msg - EXPIRED" }
    elseif ($days -lt 14) { Add-R FAIL "$msg - renew now" }
    elseif ($days -lt 30) { Add-R WARN $msg }
    else { Add-R OK $msg }
    $chainCount = (Split-PemCertificates (Get-Content -LiteralPath $full -Raw)).Count
    if ($chainCount -lt 2) { Add-R WARN 'fullchain.pem has no intermediate certificates; some clients (gRPC, Viking desktop) will reject it' }
    $dns = Get-CertificateDnsNames $x
    $missing = @($Hostnames | Where-Object { $_ -and -not (Test-CertificateCoversHost -DnsNames $dns -Hostname $_) })
    if ($missing.Count) { Add-R FAIL "certificate does not cover: $($missing -join ', ') (SAN: $($dns -join ', '))" }
    elseif ($Hostnames.Count) { Add-R OK "certificate covers all $($Hostnames.Count) hostnames" }
    $stamp = Join-Path $dir '.renewed-at'
    if (Test-Path -LiteralPath $stamp) { Add-R INFO "last installed/renewed: $((Get-Content -LiteralPath $stamp -Raw).Trim())" }
    return , $results.ToArray()
}

function Install-DockerHostCertificate {
    <#
    .SYNOPSIS
      Validate a PEM certificate + key you obtained manually and install it into Certs/<name>/.

    .DESCRIPTION
      Fails (and changes nothing) when the key does not match, the certificate is expired or not
      yet valid, or the SAN does not cover every hostname. The previous files are kept in
      Certs/<name>/previous-<stamp>/.
    #>
    param(
        [Parameter(Mandatory)][string]$CertsDir,
        [Parameter(Mandatory)][string]$CertName,
        [Parameter(Mandatory)][string]$CertPath,
        [Parameter(Mandatory)][string]$KeyPath,
        [string]$ChainPath = '',
        [string[]]$Hostnames = @(),
        [string]$PfxPassword = '',
        [switch]$Force
    )
    foreach ($p in @($CertPath, $KeyPath) + $(if ($ChainPath) { @($ChainPath) } else { @() })) {
        if (-not (Test-Path -LiteralPath $p)) { throw "File not found: $p" }
    }
    $certText = Get-Content -LiteralPath $CertPath -Raw
    $keyText = Get-Content -LiteralPath $KeyPath -Raw
    if ($keyText -match 'ENCRYPTED') { throw 'The private key is encrypted. Decrypt it first (openssl pkey -in key.pem -out key.dec.pem).' }
    $blocks = Split-PemCertificates $certText
    if (-not $blocks.Count) { throw "$CertPath contains no PEM certificate (convert DER/PFX first: openssl x509 -inform der ... or openssl pkcs12 -nokeys ...)" }
    $leafPem = $blocks[0]
    $chainBlocks = @($blocks | Select-Object -Skip 1)
    if ($ChainPath) { $chainBlocks += Split-PemCertificates (Get-Content -LiteralPath $ChainPath -Raw) }
    # Drop duplicates and a self-signed root (servers should not send it).
    $chainBlocks = @($chainBlocks | Select-Object -Unique | Where-Object {
            $c = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($_)
            $c.Subject -ne $c.Issuer
        })

    try {
        $leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($leafPem, $keyText)
    }
    catch { throw "Certificate and key do not match (or key format unsupported): $($_.Exception.Message)" }

    $now = [DateTime]::UtcNow
    if ($leaf.NotBefore.ToUniversalTime() -gt $now) { throw "Certificate is not valid until $($leaf.NotBefore)" }
    if ($leaf.NotAfter.ToUniversalTime() -lt $now) { throw "Certificate expired on $($leaf.NotAfter)" }
    $dns = Get-CertificateDnsNames $leaf
    $missing = @($Hostnames | Where-Object { $_ -and -not (Test-CertificateCoversHost -DnsNames $dns -Hostname $_) })
    if ($missing.Count) { throw "Certificate SAN ($($dns -join ', ')) does not cover: $($missing -join ', '). Ask the issuer for a SAN/wildcard cert, or set TLS_HOSTNAMES to the names this cert should serve." }
    if (-not $chainBlocks.Count) { Write-Warning 'No intermediate certificates supplied (-Chain). Clients that do not fetch intermediates will fail; get the issuer chain bundle.' }

    $dir = Join-Path $CertsDir $CertName
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $existing = Join-Path $dir 'fullchain.pem'
    if (Test-Path -LiteralPath $existing) {
        $old = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem((Split-PemCertificates (Get-Content -LiteralPath $existing -Raw))[0])
        if ($old.NotAfter -gt $leaf.NotAfter -and -not $Force) {
            throw "Installed certificate expires later ($($old.NotAfter)) than the new one ($($leaf.NotAfter)). Use -Force to replace it anyway."
        }
        $bak = Join-Path $dir ("previous-" + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
        $null = New-Item -ItemType Directory -Force -Path $bak
        Get-ChildItem -LiteralPath $dir -File -Force | Copy-Item -Destination $bak
        Write-Host "Previous files saved to $bak"
    }

    $nl = "`n"
    $chainText = ($chainBlocks -join $nl)
    Set-Content -LiteralPath (Join-Path $dir 'cert.pem') -Value ($leafPem + $nl) -NoNewline -Encoding ascii
    Set-Content -LiteralPath (Join-Path $dir 'chain.pem') -Value ($(if ($chainText) { $chainText + $nl } else { '' })) -NoNewline -Encoding ascii
    Set-Content -LiteralPath (Join-Path $dir 'fullchain.pem') -Value ((@($leafPem) + $chainBlocks) -join $nl) -NoNewline -Encoding ascii
    Add-Content -LiteralPath (Join-Path $dir 'fullchain.pem') -Value '' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $dir 'privkey.pem') -Value $keyText -NoNewline -Encoding ascii

    $pfxPwd = if ($PfxPassword) { $PfxPassword } elseif ($env:TLS_PFX_PASSWORD) { $env:TLS_PFX_PASSWORD } else { '' }
    $coll = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    [void]$coll.Add($leaf)
    foreach ($b in $chainBlocks) { [void]$coll.Add([System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($b)) }
    $pfxBytes = $coll.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $pfxPwd)
    [System.IO.File]::WriteAllBytes((Join-Path $dir 'cert.pfx'), $pfxBytes)
    Set-Content -LiteralPath (Join-Path $dir '.renewed-at') -Value ([DateTime]::UtcNow.ToString('o')) -Encoding ascii

    if (-not (Test-NornirWindowsHost)) {
        # Containers run as non-root users; match the renewer's permissions (dir 755, files 644).
        & chmod 755 $dir
        & chmod 644 (Join-Path $dir '*.pem') (Join-Path $dir 'cert.pfx')
    }
    $days = [int]($leaf.NotAfter.ToUniversalTime() - $now).TotalDays
    Write-Host "Installed $CertName ($($dns -join ', ')), expires $($leaf.NotAfter.ToString('yyyy-MM-dd')) ($days days), chain: $($chainBlocks.Count) cert(s)." -ForegroundColor Green
    Write-Host "Set TLS_MODE=manual in host.env so the viking-certs renewer leaves these files alone." -ForegroundColor Yellow
}

function Restart-TlsReloadContainers {
    <#
    .SYNOPSIS
      Restart running containers labelled viking.tls-reload=true so they load new certificates.
    #>
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warning 'docker CLI not found; restart the TLS services yourself.'
        $script:Rc = 0
        return
    }
    $ids = @(& docker ps -q --filter 'label=viking.tls-reload=true' 2>$null | Where-Object { $_ })
    if (-not $ids.Count) {
        Write-Host 'No running containers carry label viking.tls-reload=true.'
        $script:Rc = 0
        return
    }
    $names = @(& docker inspect -f '{{.Name}}' @ids) -replace '^/', ''
    Write-Host "Restarting: $($names -join ', ')"
    & docker restart @ids | Out-Null
    $script:Rc = $LASTEXITCODE
}

function Receive-DockerHostCertificate {
    <#
    .SYNOPSIS
      Copy Certs/<name>/ from a target (the host that issues certificates) into the local layout.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CertsDir,
        [Parameter(Mandatory)][string]$CertName
    )
    $dir = Join-Path $CertsDir $CertName
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $remoteDir = (($Target.Root -replace '\\', '/').TrimEnd('/')) + "/Certs/$CertName"
    foreach ($f in @('cert.pem', 'chain.pem', 'fullchain.pem', 'privkey.pem', 'cert.pfx', '.renewed-at')) {
        $scpArgs = @('-p', '-q') + @($Target.SshOptions | Where-Object { $_ }) + @("$($Target.Ssh):$remoteDir/$f", (Join-Path $dir $f))
        & scp @scpArgs
        if ($LASTEXITCODE -ne 0 -and $f -in 'fullchain.pem', 'privkey.pem') { throw "[$Name] could not fetch $remoteDir/$f" }
    }
    Write-Host "[$Name] fetched $CertName into $dir"
}

function Send-DockerHostCertificate {
    <#
    .SYNOPSIS
      Copy Certs/<name>/ to a target over scp, then reload TLS containers (Linux) or rebind IIS (Windows).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CertsDir,
        [Parameter(Mandatory)][string]$CertName
    )
    $src = Join-Path $CertsDir $CertName
    $files = @('cert.pem', 'chain.pem', 'fullchain.pem', 'privkey.pem', 'cert.pfx', '.renewed-at') |
        ForEach-Object { Join-Path $src $_ } | Where-Object { Test-Path -LiteralPath $_ }
    if (-not $files) { throw "Nothing to push: $src is empty" }
    $remoteRoot = ($Target.Root -replace '\\', '/').TrimEnd('/')
    $remoteDir = "$remoteRoot/Certs/$CertName"
    if ($Target.Os -eq 'windows') {
        $mk = "New-Item -ItemType Directory -Force -Path '$remoteDir' | Out-Null"
    }
    else {
        $mk = "mkdir -p '$remoteDir' && chmod 755 '$remoteDir'"
    }
    Invoke-Ssh -Target $Target -Command $mk
    if ($script:Rc -ne 0) { throw "[$Name] could not create $remoteDir" }
    $scpArgs = @('-p', '-q') + @($Target.SshOptions | Where-Object { $_ }) + @($files) + @("$($Target.Ssh):$remoteDir/")
    Write-Host "[$Name] scp $CertName -> $remoteDir"
    & scp @scpArgs
    if ($LASTEXITCODE -ne 0) { throw "[$Name] scp failed" }
    $reloadVerb = if ($Target.Os -eq 'windows') { 'install-iis' } else { 'reload' }
    Invoke-Ssh -Target $Target -Command (Get-RemotePwshCommand -Target $Target -StackArgs @('certs', $reloadVerb))
    if ($script:Rc -ne 0) { Write-Warning "[$Name] certs $reloadVerb exited $($script:Rc)" }
}
