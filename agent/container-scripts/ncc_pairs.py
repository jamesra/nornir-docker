"""Masked NCC per pair: StosBrute64 (ds64) and Grid32 (ds32). Usage: VOL=<volume root, required> [FILTER=Blob|Leveled] python ncc_pairs.py 565-566 ...
0.13 on ds32 Blob = registered. Pair = <mapped>-<control>. Read-only."""
import os, sys, numpy as np
if __name__ == '__main__':
    import imageio.v3 as iio
    from scipy.ndimage import map_coordinates
    from nornir_imageregistration.files import stosfile
    from nornir_imageregistration.transforms import factory
    T = (os.environ.get('VOL') or sys.exit('Set VOL to the volume root, e.g. VOL=/storage2/RC3')).rstrip('/') + '/TEM'; F = os.environ.get('FILTER', 'Blob')
    H = lambda x: x.get() if hasattr(x, 'get') else np.asarray(x)
    img = lambda s, f, d: f'{T}/{int(s):04d}/TEM/{f}/Images/{d:03d}/{int(s):04d}_TEM_{f}.png'
    def ncc(p, m, c, d):
        cb = iio.imread(img(c, F, d)).astype(np.float32); cm = iio.imread(img(c, 'Mask', d)) > 0
        mb = iio.imread(img(m, F, d)).astype(np.float32); mm = iio.imread(img(m, 'Mask', d)) > 0
        t = factory.LoadTransform(stosfile.StosFile.Load(p).Transform, 1)
        k = 3 if d == 32 else 1
        cy, cx = np.mgrid[0:cb.shape[0]:k, 0:cb.shape[1]:k]
        src = H(t.InverseTransform(np.column_stack([cy.ravel(), cx.ravel()]).astype(float)))
        v = map_coordinates(mb, src.T, order=1, cval=np.nan); vm = map_coordinates(mm.astype(np.float32), src.T, order=0) > 0
        keep = vm & cm[::k, ::k].ravel() & np.isfinite(v)
        a, b = cb[::k, ::k].ravel()[keep], v[keep]; a = a - a.mean(); b = b - b.mean()
        return float((a * b).sum() / np.sqrt((a * a).sum() * (b * b).sum())), int(keep.sum())
    print('pair\tbrute64_ncc\tgrid32_ncc\tgrid32_overlap_px')
    for pair in sys.argv[1:]:
        m, c = pair.split('-')
        b = ncc(f'{T}/StosBrute64/{pair}_ctrl-TEM_Blob_map-TEM_Blob.stos', m, c, 64) if F == 'Blob' else (float('nan'), 0)
        g = ncc(f'{T}/Grid32/{pair}_ctrl-TEM_Leveled_map-TEM_Leveled.stos', m, c, 32)
        print(f'{pair}\t{b[0]:.4f}\t{g[0]:.4f}\t{g[1]}', flush=True)
