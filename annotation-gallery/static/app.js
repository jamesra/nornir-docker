(() => {
  const state = {
    me: null,
    config: { vikingUrl: "", identityMode: "stub" },
    volume: "",
    rows: [],
    permission: "read",
    hasSam2: false,
  };

  const els = {
    who: document.getElementById("who"),
    volume: document.getElementById("volume"),
    type: document.getElementById("type"),
    label: document.getElementById("label"),
    z: document.getElementById("z"),
    radius: document.getElementById("radius"),
    ignored: document.getElementById("ignored"),
    sort: document.getElementById("sort"),
    status: document.getElementById("status"),
    scroller: document.getElementById("scroller"),
    spacer: document.getElementById("spacer"),
    grid: document.getElementById("grid"),
  };

  const CARD = 232;

  async function getJson(url, options) {
    const response = await fetch(url, options);
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new Error(payload.error || response.statusText);
      error.status = response.status;
      throw error;
    }
    return payload;
  }

  function fileUrl(volume, rel) {
    return `/api/volumes/${encodeURIComponent(volume)}/file?path=${encodeURIComponent(rel)}`;
  }

  function vikingHref(row) {
    const template = state.config.vikingUrl || "";
    return template
      .replaceAll("{volume}", encodeURIComponent(state.volume))
      .replaceAll("{id}", encodeURIComponent(String(row.location_id)));
  }

  function parseRadius(text) {
    const trimmed = text.trim();
    if (!trimmed) {
      return null;
    }
    if (trimmed.includes("-")) {
      const [lo, hi] = trimmed.split("-", 2).map(Number);
      return { lo, hi };
    }
    const value = Number(trimmed);
    return Number.isFinite(value) ? { lo: value, hi: value } : null;
  }

  function filtered() {
    const type = els.type.value.trim().toLowerCase();
    const label = els.label.value.trim().toLowerCase();
    const zText = els.z.value.trim();
    const radius = parseRadius(els.radius.value);
    const ignored = els.ignored.value;
    return state.rows.filter((row) => {
      if (ignored === "active" && row.ignored) {
        return false;
      }
      if (ignored === "ignored" && !row.ignored) {
        return false;
      }
      if (zText && String(row.z) !== zText) {
        return false;
      }
      if (type) {
        const hay = `${row.type_id || ""} ${row.type_name || ""}`.toLowerCase();
        if (!hay.includes(type)) {
          return false;
        }
      }
      if (label) {
        const hay = `${row.structure_label || ""}`.toLowerCase();
        if (!hay.includes(label)) {
          return false;
        }
      }
      if (radius) {
        const value = Number(row.radius);
        if (!Number.isFinite(value) || value < radius.lo || value > radius.hi) {
          return false;
        }
      }
      return true;
    }).sort((left, right) => {
      const key = els.sort.value;
      const a = left[key];
      const b = right[key];
      if (a == null && b == null) {
        return left.location_id - right.location_id;
      }
      if (a == null) {
        return 1;
      }
      if (b == null) {
        return -1;
      }
      if (typeof a === "string" || typeof b === "string") {
        return String(a).localeCompare(String(b));
      }
      return a - b;
    });
  }

  function cardHtml(row) {
    const image = fileUrl(state.volume, row.image_relpath || row.jpeg_relpath);
    const mask = fileUrl(state.volume, row.mask_relpath);
    const sam2 = row.sam2GtIou == null ? "" : `<span class="badge">SAM2 ${Number(row.sam2GtIou).toFixed(2)}</span>`;
    const action = row.ignored
      ? `<button class="icon plus" data-act="restore" data-id="${row.location_id}" title="Restore">+</button>`
      : `<button class="icon trash" data-act="ignore" data-id="${row.location_id}" title="Ignore">Trash</button>`;
    return `
      <article class="card" data-id="${row.location_id}">
        <div class="composite">
          <img class="jpeg" alt="" src="${image}">
          <div class="tint" style="mask-image:url('${mask}');-webkit-mask-image:url('${mask}')"></div>
        </div>
        <div class="meta">
          <div>#${row.location_id} · Z ${row.z} · r ${row.radius == null ? "—" : Number(row.radius).toFixed(1)}</div>
          <div>${row.type_name || "type"} ${row.type_id || ""} · ${row.structure_label || "unlabeled"} ${sam2}</div>
          <div class="actions">
            <a href="${vikingHref(row)}" target="_blank" rel="noreferrer">Viking</a>
            ${action}
          </div>
        </div>
      </article>`;
  }

  function render() {
    const rows = filtered();
    const columns = Math.max(1, Math.floor(els.grid.clientWidth / CARD) || 1);
    const rowHeight = CARD;
    const totalRows = Math.ceil(rows.length / columns) || 1;
    els.spacer.style.height = `${totalRows * rowHeight}px`;
    const scroll = els.scroller.scrollTop;
    const viewH = els.scroller.clientHeight;
    const first = Math.max(0, Math.floor(scroll / rowHeight) - 2);
    const last = Math.min(totalRows, Math.ceil((scroll + viewH) / rowHeight) + 2);
    const start = first * columns;
    const end = Math.min(rows.length, last * columns);
    els.grid.style.top = `${first * rowHeight}px`;
    els.grid.innerHTML = rows.slice(start, end).map(cardHtml).join("");
    els.status.textContent = `${rows.length} location(s) · ${state.permission}`;
  }

  async function loadCatalog() {
    if (!state.volume) {
      state.rows = [];
      render();
      return;
    }
    const payload = await getJson(`/api/volumes/${encodeURIComponent(state.volume)}/catalog`);
    state.rows = payload.rows || [];
    state.permission = payload.permission || "read";
    document.body.classList.toggle("no-review", state.permission !== "review");
    state.hasSam2 = state.rows.some((row) =>
      row.sam2PredIou != null || row.sam2ObjectScore != null || row.sam2Stability != null || row.sam2GtIou != null
    );
    const sam2Option = els.sort.querySelector('option[value="sam2GtIou"]');
    if (state.hasSam2 && !sam2Option) {
      const option = document.createElement("option");
      option.value = "sam2GtIou";
      option.textContent = "SAM2 GT IoU";
      els.sort.appendChild(option);
    }
    if (!state.hasSam2 && sam2Option) {
      sam2Option.remove();
    }
    render();
  }

  async function mutate(act, locationId) {
    await getJson(`/api/volumes/${encodeURIComponent(state.volume)}/${act}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ location_id: locationId }),
    });
    await loadCatalog();
  }

  els.grid.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-act]");
    if (!button) {
      return;
    }
    mutate(button.dataset.act, Number(button.dataset.id)).catch((error) => {
      els.status.textContent = error.message;
    });
  });

  ["input", "change"].forEach((name) => {
    els.type.addEventListener(name, render);
    els.label.addEventListener(name, render);
    els.z.addEventListener(name, render);
    els.radius.addEventListener(name, render);
    els.ignored.addEventListener(name, render);
    els.sort.addEventListener(name, render);
  });
  els.volume.addEventListener("change", () => {
    state.volume = els.volume.value;
    loadCatalog().catch((error) => {
      els.status.textContent = error.message;
    });
  });
  els.scroller.addEventListener("scroll", render);
  window.addEventListener("resize", render);

  async function boot() {
    state.config = await getJson("/api/config");
    state.me = await getJson("/api/me");
    const volumes = state.me.volumes || [];
    els.who.textContent = `${state.me.displayName} (${state.config.identityMode})`;
    els.volume.innerHTML = volumes
      .map((item) => `<option value="${item.name}">${item.name} · ${item.permission}</option>`)
      .join("");
    const volumeWrap = els.volume.closest("label");
    if (volumes.length <= 1) {
      volumeWrap.style.display = volumes.length ? "none" : "flex";
    }
    state.volume = volumes[0] ? volumes[0].name : "";
    if (!volumes.length) {
      els.status.textContent = "No volumes with Read access in the registry.";
      return;
    }
    await loadCatalog();
  }

  boot().catch((error) => {
    els.status.textContent = error.message;
  });
})();
