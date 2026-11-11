for w in listsuffix binarytrees mixedmedium requests losarrays mediumarrays; do
  python3 /root/dl/dl-run.py /root/dl/out/exp1 1 $w old,oldbig default
done
echo EXP1DONE
