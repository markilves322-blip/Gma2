import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('capture_csv', ROOT/'tools/capture_csv.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)

class CaptureTests(unittest.TestCase):
    def profile(self, view='front'):
        return json.loads((ROOT/f'examples/venue-{view}.json').read_text())

    def test_front_and_top_projections(self):
        csv = (ROOT/'examples/scene-synthetic.csv').read_text()
        _, front = capture.convert(csv, self.profile())
        _, top = capture.convert(csv, self.profile('top'))
        self.assertEqual((front['placements'][1]['x'],front['placements'][1]['y']), (0,12))
        self.assertEqual((top['placements'][1]['x'],top['placements'][1]['y']), (0,-4))

    def test_explicit_id_map_requires_all_ids(self):
        p = self.profile(); p['id_map']={'1':101}
        text, report = capture.convert('Channel,X,Z\n1,2,3\n',p)
        self.assertIn('101\t4.000000\t6.000000',text)
        self.assertEqual(report['id_match'],'explicit map')
        with self.assertRaises(ValueError): capture.convert('Channel,X,Z\n2,2,3',p)

    def test_duplicate_target_id_mapping(self):
        p = self.profile(); p['id_map']={'1':101,'2':101}
        with self.assertRaises(ValueError): capture.convert('Channel,X,Z\n1,2,3\n2,4,5',p)

    def test_bom_semicolon_decimal_comma_origin(self):
        p = self.profile(); p.update(delimiter=';',origin={'x':1,'z':2})
        text,_=capture.convert('\ufeffChannel;X;Z\r\n101;1,5;2,5\r\n',p)
        self.assertIn('101\t1.000000\t1.000000',text)

    def test_bad_or_missing_coordinates_and_ids(self):
        for row in ['101,nan,2','101,inf,2','101,,2','101,2','101,2,3,4','1.5,2,3','-1,2,3','101,foo,2']:
            with self.subTest(row=row),self.assertRaises((ValueError,TypeError)):
                capture.convert('Channel,X,Z\n'+row,self.profile())

    def test_headers_not_guessed(self):
        for csv in ['Channel,X,X\n1,2,3','Unit,X,Z\n1,2,3','Channel,X,Z\n']:
            with self.assertRaises(ValueError): capture.convert(csv,self.profile())

    def test_invalid_projection_and_scale(self):
        for update in [{'horizontal_axis':'z'}, {'scale':0}, {'scale':-1}, {'horizontal_sign':0}]:
            p=self.profile();p.update(update)
            with self.assertRaises(ValueError):capture.convert('Channel,X,Z\n101,1,2',p)

    def test_overlap_warning_and_explicit_delta(self):
        p=self.profile();p['columns']['rotation_delta']='delta'
        _,r=capture.convert('Channel,X,Z,delta\n101,0,2,30\n201,0,2,-30',p)
        self.assertEqual(r['placements'][1]['rotation_delta'],-30)
        self.assertEqual(len(r['warnings']),1)

if __name__=='__main__':unittest.main()
