#!/usr/bin/env python3
"""Read-only validation of the four BMPs and their regular-file raw image."""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from PIL import Image


def validate(directory):
    manifest=json.loads((directory/'manifest.json').read_text(encoding='utf-8'))
    image=(directory/'cpr-tutorials-training-safe.img').read_bytes()
    assert len(manifest['cards'])==4
    assert len(image)==manifest['image_bytes']
    assert hashlib.sha256(image).hexdigest()==manifest['image_sha256']
    current_sector=0
    for index,card in enumerate(manifest['cards']):
        assert index==card['index_zero_based'] and card['start_sector']==current_sector
        path=(directory/card['file']).resolve()
        assert path.is_relative_to(directory.resolve())
        raw=path.read_bytes()
        assert len(raw)==card['bytes']==921654
        assert hashlib.sha256(raw).hexdigest()==card['sha256']
        assert raw[:2]==b'BM'
        assert struct.unpack_from('<I',raw,10)[0]==54
        assert struct.unpack_from('<iiHHI',raw,18)==(640,480,1,24,0)
        start=card['start_sector']*512
        assert image[start:start+len(raw)]==raw
        padding=(-(start+len(raw)))%512
        assert padding==card['padding_bytes']
        assert not any(image[start+len(raw):start+len(raw)+padding])
        with Image.open(path) as actual:
            assert actual.mode=='RGB' and actual.size==(640,480)
            # The protected header, training panel, and subtitle windows
            # remain clear. The complete source card is inside the viewport.
            bg=Image.new('RGB',(640,480),'#102030')
            bg.paste(actual.crop((16,32,368,432)),(16,32))
            assert actual.tobytes()==bg.tobytes()
        current_sector += (len(raw)+511)//512
    assert len(image)==current_sector*512
    return {'status':'passed','cards':4,'width':640,'height':480,'bits_per_pixel':24,
            'start_sectors':[c['start_sector'] for c in manifest['cards']],
            'raw_image_bytes':len(image),'raw_image_sha256':manifest['image_sha256'],
            'safe_viewport_pixels_preserved':True,'physical_device_accessed':False}


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',type=Path)
    p.add_argument('--output',type=Path)
    args=p.parse_args()
    result=validate(args.directory)
    if args.output:args.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))
