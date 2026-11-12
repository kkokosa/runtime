## Old default / new default / new with an explicit large reserve (LXRImmixReserveMB=60000, LXRNativePlaneLimitMB=250000), 10 pairs

| workload | metric | old median | new median | new - old (paired median, 95% interval) | newbig median | newbig - old (paired median, 95% interval) |
|---|---|---|---|---|---|---|
| binarytrees | wall ms | 1090.8 | 1101.6 | +8.5 [-42.1, +52.6] | 1053.1 | -31.0 [-75.7, -8.4] |
| binarytrees | CPU ms | 2924.9 | 2904.4 | +41.3 [-558.3, +489.7] | 2365.7 | -436.8 [-997.9, -227.0] |
| binarytrees | pause ms | 132.9 | 144.2 | +16.6 [-34.2, +25.5] | 108.9 | -18.6 [-42.1, -7.1] |
| binarytrees | collections | 35.0 | 38.0 | +0.0 [-5.5, +6.0] | 22.0 | -12.5 [-16.0, -5.5] |
| binarytrees | peak RSS MB | 202.4 | 210.4 | +11.6 [+0.2, +14.7] | 245.9 | +43.2 [+24.7, +52.2] |
| listsuffix | wall ms | 1250.9 | 1297.3 | +41.6 [+0.2, +86.2] | 1373.1 | +135.5 [+84.7, +197.6] |
| listsuffix | CPU ms | 3311.3 | 3377.4 | +144.1 [-23.5, +316.6] | 3614.3 | +261.8 [+185.5, +348.3] |
| listsuffix | pause ms | 168.0 | 172.7 | +9.5 [-4.3, +23.4] | 181.1 | +9.1 [+6.8, +29.3] |
| listsuffix | collections | 6.0 | 6.0 | +0.0 [+0.0, +1.0] | 5.0 | -1.0 [-1.0, -1.0] |
| listsuffix | peak RSS MB | 198.6 | 201.9 | +5.3 [-0.0, +6.9] | 285.2 | +85.3 [+69.3, +89.7] |
| losarrays | wall ms | 1090.4 | 1088.0 | -9.2 [-59.2, +4.4] | 1095.0 | +1.4 [-34.6, +55.3] |
| losarrays | CPU ms | 2411.1 | 2410.1 | +11.9 [-77.6, +79.1] | 2404.5 | -16.6 [-72.2, +130.9] |
| losarrays | pause ms | 428.0 | 417.3 | -8.7 [-15.2, -2.2] | 423.1 | -6.1 [-10.4, +12.2] |
| losarrays | collections | 49.0 | 49.0 | +0.0 [+0.0, +0.0] | 49.0 | +0.0 [+0.0, +0.0] |
| losarrays | peak RSS MB | 105.2 | 108.8 | +3.5 [+3.3, +3.9] | 112.3 | +7.0 [+6.9, +7.4] |
| mediumarrays | wall ms | FAILED in 10 of 10 runs | | | | |
| mediumarrays | CPU ms | FAILED in 10 of 10 runs | | | | |
| mediumarrays | pause ms | FAILED in 10 of 10 runs | | | | |
| mediumarrays | collections | FAILED in 10 of 10 runs | | | | |
| mediumarrays | peak RSS MB | FAILED in 10 of 10 runs | | | | |
| mixedmedium | wall ms | 1369.5 | 1309.2 | -51.9 [-65.9, -17.2] | 825.8 | -546.7 [-582.7, -495.8] |
| mixedmedium | CPU ms | 2393.9 | 2307.4 | -85.9 [-102.9, -14.9] | 1705.4 | -710.8 [-772.7, -606.0] |
| mixedmedium | pause ms | 196.8 | 191.4 | -0.8 [-7.0, +7.0] | 109.4 | -84.1 [-93.6, -72.3] |
| mixedmedium | collections | 223.0 | 219.0 | -3.5 [-12.5, -2.0] | 15.0 | -208.0 [-212.0, -207.0] |
| mixedmedium | peak RSS MB | 192.6 | 197.6 | +5.0 [+4.8, +5.3] | 381.4 | +188.9 [+184.2, +192.4] |
| requests | wall ms | 361.5 | 349.8 | -1.4 [-21.3, +3.4] | 355.0 | -7.4 [-26.2, +3.9] |
| requests | CPU ms | 483.3 | 473.3 | -5.8 [-28.9, +10.8] | 472.1 | -5.6 [-31.1, +6.3] |
| requests | pause ms | 29.5 | 28.6 | +0.3 [-2.1, +2.1] | 29.4 | +0.2 [-1.5, +1.9] |
| requests | collections | 9.0 | 9.0 | +0.0 [+0.0, +0.0] | 9.0 | +0.0 [+0.0, +0.0] |
| requests | peak RSS MB | 170.5 | 174.2 | +3.6 [+3.2, +4.0] | 178.0 | +7.4 [+7.1, +8.0] |

runs 180, not ok 10: old/mediumarrays:failed

## mediumarrays at the defaults: old fails in 10 of 10 runs, so the base is the new default

| workload | metric | new median | newbig median | newbig - new (paired median, 95% interval) |
|---|---|---|---|---|
| mediumarrays | wall ms | 1241.1 | 1043.1 | -224.4 [-280.3, -181.7] |
| mediumarrays | CPU ms | 1878.0 | 1792.3 | -108.3 [-248.0, -7.3] |
| mediumarrays | pause ms | 145.0 | 138.7 | -5.7 [-15.1, +17.4] |
| mediumarrays | collections | 97.5 | 19.0 | -79.0 [-81.0, -77.0] |
| mediumarrays | peak RSS MB | 254.6 | 466.3 | +211.9 [+208.4, +257.4] |
runs 180, not ok 10: old/mediumarrays:failed

## mediumarrays with the explicit settings of the standard runs (InitialMB=200 ReserveMB=400): old and new

| workload | metric | old median | new median | new - old (paired median, 95% interval) |
|---|---|---|---|---|
| mediumarrays | wall ms | 937.1 | 933.5 | -0.4 [-21.4, +14.3] |
| mediumarrays | CPU ms | 1743.4 | 1735.8 | -1.7 [-38.0, +22.6] |
| mediumarrays | pause ms | 95.1 | 96.1 | +0.5 [-1.5, +3.1] |
| mediumarrays | collections | 14.0 | 14.0 | +0.0 [+0.0, +0.0] |
| mediumarrays | peak RSS MB | 482.3 | 482.0 | -0.2 [-0.6, -0.0] |

runs 20, not ok 0: 

## Isolation: old, new default, new with LXRImmixReserveMB=128 set explicitly (10 pairs)

| workload | metric | old median | new median | new - old (paired median, 95% interval) | newr128 median | newr128 - old (paired median, 95% interval) |
|---|---|---|---|---|---|---|
| binarytrees | wall ms | 1103.7 | 1107.0 | -0.6 [-24.8, +42.1] | 1099.1 | +12.2 [-36.6, +41.4] |
| binarytrees | CPU ms | 3078.6 | 2650.1 | -458.2 [-1131.4, +260.5] | 3074.6 | -137.2 [-465.8, +349.0] |
| binarytrees | pause ms | 140.6 | 136.8 | -19.3 [-56.3, +16.2] | 141.2 | +5.9 [-29.8, +14.5] |
| binarytrees | collections | 34.5 | 32.0 | -6.0 [-13.0, +2.5] | 30.0 | -1.0 [-8.0, +4.0] |
| binarytrees | peak RSS MB | 203.3 | 210.1 | +10.0 [+1.8, +75.4] | 204.6 | -0.8 [-4.0, +3.0] |
| listsuffix | wall ms | 1233.6 | 1235.7 | +39.3 [-54.2, +71.3] | 1215.9 | +11.1 [-48.4, +52.8] |
| listsuffix | CPU ms | 3384.1 | 3329.2 | -54.5 [-262.3, +90.4] | 3414.5 | +6.8 [-165.7, +127.4] |
| listsuffix | pause ms | 171.2 | 171.4 | -2.8 [-20.1, +8.8] | 173.5 | +0.3 [-10.5, +8.3] |
| listsuffix | collections | 6.0 | 6.0 | +0.0 [-1.0, +0.0] | 6.0 | +0.0 [+0.0, +0.0] |
| listsuffix | peak RSS MB | 198.8 | 204.8 | +3.5 [+0.3, +7.8] | 197.3 | -0.6 [-3.6, +1.0] |

runs 60, not ok 0: 

## LOS default: old (7e4d693af24) / prev (Immix default only, bee59a41835) / new (LOS default), no setting, 10 pairs

| workload | metric | old median | prev median | prev - old (paired median, 95% interval) | new median | new - old (paired median, 95% interval) |
|---|---|---|---|---|---|---|
| losarrays | wall ms | 1180.2 | 1185.4 | -17.7 [-67.5, +41.9] | 1199.2 | +5.6 [-0.2, +34.1] |
| losarrays | CPU ms | 2522.6 | 2503.2 | -42.0 [-87.7, +74.4] | 2580.7 | +71.7 [+27.7, +125.8] |
| losarrays | pause ms | 479.7 | 460.3 | -13.6 [-34.8, -3.7] | 474.8 | -1.8 [-10.6, +10.3] |
| losarrays | collections | 49.0 | 49.0 | +0.0 [+0.0, +0.0] | 49.0 | +0.0 [+0.0, +0.0] |
| losarrays | peak RSS MB | 105.3 | 109.1 | +3.8 [+3.7, +3.9] | 108.6 | +3.5 [+3.1, +3.6] |
| losmany | wall ms | FAILED in 10 of 10 runs | | | | |
| losmany | CPU ms | FAILED in 10 of 10 runs | | | | |
| losmany | pause ms | FAILED in 10 of 10 runs | | | | |
| losmany | collections | FAILED in 10 of 10 runs | | | | |
| losmany | peak RSS MB | FAILED in 10 of 10 runs | | | | |
| mediumarrays | wall ms | FAILED in 10 of 10 runs | | | | |
| mediumarrays | CPU ms | FAILED in 10 of 10 runs | | | | |
| mediumarrays | pause ms | FAILED in 10 of 10 runs | | | | |
| mediumarrays | collections | FAILED in 10 of 10 runs | | | | |
| mediumarrays | peak RSS MB | FAILED in 10 of 10 runs | | | | |
| requests | wall ms | 382.4 | 387.8 | +4.7 [-33.4, +16.3] | 385.5 | -3.3 [-21.6, +13.2] |
| requests | CPU ms | 502.7 | 510.7 | +7.2 [-42.3, +22.1] | 505.4 | +4.1 [-24.3, +15.8] |
| requests | pause ms | 29.6 | 29.7 | -0.1 [-8.9, +2.4] | 29.2 | -0.6 [-8.4, +0.6] |
| requests | collections | 9.0 | 9.0 | +0.0 [+0.0, +0.0] | 9.0 | +0.0 [+0.0, +0.0] |
| requests | peak RSS MB | 170.2 | 174.1 | +3.9 [+3.6, +4.3] | 173.6 | +3.5 [+3.0, +3.8] |

runs 120, not ok 30: old/losmany:failed, old/mediumarrays:failed, prev/losmany:failed

## mediumarrays: prev against new (the old default fails)

| workload | metric | prev median | new median | new - prev (paired median, 95% interval) |
|---|---|---|---|---|
| mediumarrays | wall ms | 1349.1 | 1321.6 | -6.8 [-30.8, +41.0] |
| mediumarrays | CPU ms | 2020.8 | 2013.3 | +18.8 [-31.6, +45.9] |
| mediumarrays | pause ms | 158.6 | 156.8 | -2.3 [-7.5, +5.8] |
| mediumarrays | collections | 97.5 | 97.5 | +0.5 [-1.0, +1.5] |
| mediumarrays | peak RSS MB | 255.1 | 254.8 | -0.3 [-0.9, -0.1] |
runs 120, not ok 30: old/losmany:failed, old/mediumarrays:failed, prev/losmany:failed

## standard explicit settings (mediumarrays InitialMB=200 ReserveMB=400; losmany LOSInitialMB=1000 LOSReserveMB=1600 NativePlaneLimitMB=16000): old and new

| workload | metric | old median | new median | new - old (paired median, 95% interval) |
|---|---|---|---|---|
| losmany | wall ms | 1125.5 | 1184.5 | +65.8 [-73.4, +143.7] |
| losmany | CPU ms | 2755.0 | 2786.4 | +35.4 [-95.3, +127.8] |
| losmany | pause ms | 210.3 | 219.6 | +9.3 [-34.1, +57.5] |
| losmany | collections | 73.0 | 73.0 | +0.0 [-15.0, +0.0] |
| losmany | peak RSS MB | 180.9 | 181.0 | +0.0 [-0.4, +77.0] |
| mediumarrays | wall ms | 1002.8 | 1006.1 | +2.0 [-22.9, +47.4] |
| mediumarrays | CPU ms | 1758.9 | 1799.6 | +44.3 [-11.7, +89.3] |
| mediumarrays | pause ms | 86.3 | 90.1 | +3.6 [-2.4, +7.2] |
| mediumarrays | collections | 14.0 | 14.0 | +0.0 [+0.0, +0.0] |
| mediumarrays | peak RSS MB | 482.2 | 481.4 | -0.8 [-1.0, -0.6] |

runs 40, not ok 0: 

## losarrays isolation, 15 pairs: old, prev, new, new with LXRLOSReserveMB=256 set explicitly

| workload | metric | old median | prev median | prev - old (paired median, 95% interval) | new median | new - old (paired median, 95% interval) | newlos256 median | newlos256 - old (paired median, 95% interval) |
|---|---|---|---|---|---|---|---|---|
| losarrays | wall ms | 1190.1 | 1209.8 | -1.5 [-15.5, +16.2] | 1217.8 | +11.1 [-7.9, +13.0] | 1234.6 | +8.3 [-17.5, +19.4] |
| losarrays | CPU ms | 2554.9 | 2646.0 | -3.2 [-48.7, +70.8] | 2633.4 | +66.9 [+10.6, +89.7] | 2597.7 | -13.5 [-58.2, +22.4] |
| losarrays | pause ms | 488.8 | 492.6 | -1.3 [-7.9, +7.3] | 491.3 | +1.4 [-2.8, +18.6] | 495.8 | +2.8 [-13.7, +10.0] |
| losarrays | collections | 49.0 | 49.0 | +0.0 [+0.0, +0.0] | 49.0 | +0.0 [+0.0, +0.0] | 49.0 | +0.0 [+0.0, +0.0] |
| losarrays | peak RSS MB | 105.3 | 108.9 | +3.6 [+3.5, +3.9] | 108.6 | +3.3 [+3.2, +3.5] | 108.4 | +3.2 [+3.0, +3.4] |

runs 60, not ok 0: 

## losmany at the new default (10 runs, medians): wall 1137.5 ms, CPU 2818.3 ms, pause 222.8 ms, collections 67, peak RSS 184.2 MB; old and prev: 10 of 10 fail

## Commit-on-demand fix: new (d67c equivalent, 42d36e175e5) against fix (05c792703fd), no setting, 10 pairs

| workload | metric | new median | fix median | fix - new (paired median, 95% interval) |
|---|---|---|---|---|
| listsuffix | wall ms | 1207.4 | 1197.3 | -19.3 [-102.2, +23.4] |
| listsuffix | CPU ms | 3161.5 | 3172.8 | -37.7 [-154.0, +65.1] |
| listsuffix | pause ms | 159.4 | 157.3 | -4.0 [-7.9, +0.9] |
| listsuffix | collections | 6.0 | 6.0 | +0.0 [+0.0, +0.0] |
| listsuffix | peak RSS MB | 204.0 | 197.1 | -7.0 [-8.2, -3.1] |
| losarrays | wall ms | 1096.7 | 1091.9 | -4.7 [-65.1, +33.9] |
| losarrays | CPU ms | 2446.5 | 2400.6 | -13.4 [-164.2, +22.0] |
| losarrays | pause ms | 433.2 | 435.5 | +2.9 [-6.0, +14.2] |
| losarrays | collections | 49.0 | 49.0 | +0.0 [+0.0, +0.0] |
| losarrays | peak RSS MB | 108.6 | 104.7 | -4.1 [-4.2, -3.8] |
| losmany | wall ms | 1048.2 | 1037.0 | -13.7 [-48.8, +30.3] |
| losmany | CPU ms | 2662.9 | 2616.9 | -49.7 [-107.3, +16.7] |
| losmany | pause ms | 197.4 | 197.1 | -0.6 [-10.1, +6.9] |
| losmany | collections | 67.0 | 67.0 | +0.0 [+0.0, +0.0] |
| losmany | peak RSS MB | 184.1 | 180.1 | -3.9 [-4.2, -3.8] |
| mixedmedium | wall ms | 1333.0 | 1347.0 | +11.2 [-40.2, +49.5] |
| mixedmedium | CPU ms | 2303.5 | 2317.2 | +23.0 [-64.2, +68.8] |
| mixedmedium | pause ms | 197.6 | 196.6 | +1.6 [-12.6, +11.0] |
| mixedmedium | collections | 219.5 | 217.0 | -2.5 [-9.0, +2.5] |
| mixedmedium | peak RSS MB | 197.2 | 193.4 | -3.8 [-4.4, -3.3] |
| requests | wall ms | 360.7 | 365.7 | +13.7 [+0.2, +19.5] |
| requests | CPU ms | 477.9 | 486.1 | +13.0 [+1.1, +28.7] |
| requests | pause ms | 28.7 | 29.0 | +0.6 [-0.2, +2.1] |
| requests | collections | 9.0 | 9.0 | +0.0 [+0.0, +0.0] |
| requests | peak RSS MB | 173.8 | 169.8 | -3.9 [-4.7, -3.7] |

runs 100, not ok 0: 

## requests only, 20 more pairs

| workload | metric | new median | fix median | fix - new (paired median, 95% interval) |
|---|---|---|---|---|
| requests | wall ms | 352.6 | 353.7 | +3.1 [-3.8, +15.3] |
| requests | CPU ms | 466.5 | 472.8 | +4.6 [-3.1, +16.2] |
| requests | pause ms | 28.7 | 28.8 | -0.1 [-1.0, +0.6] |
| requests | collections | 9.0 | 9.0 | +0.0 [+0.0, +0.0] |
| requests | peak RSS MB | 173.7 | 169.7 | -4.0 [-4.1, -3.7] |

runs 40, not ok 0: 
