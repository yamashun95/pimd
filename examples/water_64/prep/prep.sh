prep_liquid.x
rm -f geometry.ini
mv centroid.txyz water_64.txyz
convert_tinker.x water_64.txyz oplsaa.prm 17.0 20.0 mm.dat centroid.dat structure.dat tmp.dat
rm -f tmp.dat
