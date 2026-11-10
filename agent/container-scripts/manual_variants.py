"""Score StosBrute64/Manual poses as saved and direction-reversed at ds64 Blob (read-only). Usage: [VOL=...] python manual_variants.py <pair> ..."""
import os, sys, numpy as np
if __name__ == '__main__':
    import imageio.v3 as iio
    from scipy.ndimage import map_coordinates
    from nornir_imageregistration.files import stosfile
    from nornir_imageregistration.transforms import factory
    T = (os.environ.get('VOL') or sys.exit('Set VOL to the volume root, e.g. VOL=/storage2/RC3')).rstrip('/') + '/TEM'; H = lambda x: x.get() if hasattr(x, 'get') else np.asarray(x)
    img = lambda s, f, d: f'{T}/{int(s):04d}/TEM/{f}/Images/{d:03d}/{int(s):04d}_TEM_{f}.png'
    def ncc(fn, m, c):
        cb = iio.imread(img(c, 'Blob', 64)).astype(np.float32); cm = iio.imread(img(c, 'Mask', 64)) > 0
        mb = iio.imread(img(m, 'Blob', 64)).astype(np.float32); mm = iio.imread(img(m, 'Mask', 64)) > 0
        cy, cx = np.mgrid[0:cb.shape[0], 0:cb.shape[1]]
        src = H(fn(np.column_stack([cy.ravel(), cx.ravel()]).astype(float)))
        v = map_coordinates(mb, src.T, order=1, cval=np.nan); vm = map_coordinates(mm.astype(np.float32), src.T, order=0) > 0
        keep = vm & cm.ravel() & np.isfinite(v)
        if keep.sum() < 100: return float('nan')
        a, b = cb.ravel()[keep], v[keep]; a = a - a.mean(); b = b - b.mean()
        return float((a * b).sum() / np.sqrt((a * a).sum() * (b * b).sum()))
    print('pair\tas_saved\treversed')
    for pair in sys.argv[1:]:
        m, c = pair.split('-')
        t = factory.LoadTransform(stosfile.StosFile.Load(f'{T}/StosBrute64/Manual/{pair}_ctrl-TEM_Blob_map-TEM_Blob.stos').Transform, 1)
        print(f'{pair}\t{ncc(t.InverseTransform, m, c):.4f}\t{ncc(t.Transform, m, c):.4f}', flush=True)
