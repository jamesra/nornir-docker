"""Scratch Grid32 refine variants for failing manual RC3 pairs (read-only on RC3; writes /tmp/rvar).
Input = StosBrute64/<pair> (the copied manual) rescaled 64->32 like the pipeline. A: cell 512, spacing 192, 5 it.
B (only if A < 0.13): A + angles -15..15 step 3 deg. Score = masked ds32 Blob NCC (0.13 = registered)."""
import os, sys, time, numpy as np
if __name__ == '__main__':
    from nornir_imageregistration import computational_lib
    computational_lib.SetActiveComputationLib(computational_lib.ComputationLib.cupy)
    import nornir_imageregistration.local_distortion_correction as ldc
    from nornir_imageregistration.files import stosfile
    from nornir_imageregistration.transforms import factory
    import imageio.v3 as iio
    from scipy.ndimage import map_coordinates
    T = os.environ.get('VOL', '/storage2/RC3').rstrip('/') + '/TEM'; O = '/tmp/rvar'; os.makedirs(O, exist_ok=True)
    H = lambda x: x.get() if hasattr(x, 'get') else np.asarray(x)
    img = lambda s, f, d: f'{T}/{int(s):04d}/TEM/{f}/Images/{d:03d}/{int(s):04d}_TEM_{f}.png'
    def ncc(p, m, c):
        cb = iio.imread(img(c, 'Blob', 32)).astype(np.float32); cm = iio.imread(img(c, 'Mask', 32)) > 0
        mb = iio.imread(img(m, 'Blob', 32)).astype(np.float32); mm = iio.imread(img(m, 'Mask', 32)) > 0
        t = factory.LoadTransform(stosfile.StosFile.Load(p).Transform, 1)
        cy, cx = np.mgrid[0:cb.shape[0]:3, 0:cb.shape[1]:3]
        src = H(t.InverseTransform(np.column_stack([cy.ravel(), cx.ravel()]).astype(float)))
        v = map_coordinates(mb, src.T, order=1, cval=np.nan); vm = map_coordinates(mm.astype(np.float32), src.T, order=0) > 0
        keep = vm & cm[::3, ::3].ravel() & np.isfinite(v)
        if keep.sum() < 100: return float('nan')
        a, b = cb[::3, ::3].ravel()[keep], v[keep]; a = a - a.mean(); b = b - b.mean()
        return float((a * b).sum() / np.sqrt((a * a).sum() * (b * b).sum()))
    ANG = list(range(-15, 16, 3))
    print('pair\tinput_ncc\tA_cell512_ncc\tA_s\tB_cell512_ang15_ncc\tB_s', flush=True)
    for pair in sys.argv[1:]:
        m, c = pair.split('-'); n64 = f'{T}/StosBrute64/{pair}_ctrl-TEM_Blob_map-TEM_Blob.stos'
        i32 = f'{O}/{pair}_in32.stos'
        stosfile.StosFile.Load(n64).ChangeTransformPixelSpacing(64, 32, img(c, 'Leveled', 32), img(m, 'Leveled', 32), img(c, 'Mask', 32), img(m, 'Mask', 32)).Save(i32)
        n0 = ncc(i32, m, c); row = [f'{n0:.4f}']
        try:
            t0 = time.perf_counter(); ldc.RefineStosFile(i32, f'{O}/{pair}_A.stos', num_iterations=5, cell_size=(512, 512), grid_spacing=(192, 192))
            na = ncc(f'{O}/{pair}_A.stos', m, c); row += [f'{na:.4f}', f'{time.perf_counter() - t0:.0f}']
        except Exception as e:
            na = float('nan'); row += [f'err {e.__class__.__name__}: {str(e)[:60]}', '']
        if not (na >= 0.13):
            try:
                t0 = time.perf_counter(); ldc.RefineStosFile(i32, f'{O}/{pair}_B.stos', num_iterations=5, cell_size=(512, 512), grid_spacing=(192, 192), angles_to_search=ANG)
                row += [f"{ncc(f'{O}/{pair}_B.stos', m, c):.4f}", f'{time.perf_counter() - t0:.0f}']
            except Exception as e:
                row += [f'err {e.__class__.__name__}: {str(e)[:60]}', '']
        else:
            row += ['skip', '']
        print(pair + '\t' + '\t'.join(row), flush=True)
