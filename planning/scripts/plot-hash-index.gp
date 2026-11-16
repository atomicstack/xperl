if (ARG3 eq "png") {
    set terminal pngcairo size 1100,900 font "DejaVu Sans,12"
} else {
    set terminal svg size 1100,900 font "DejaVu Sans,12"
}
set output ARG2
set datafile separator "\t"
plot_title = exists("ARG4") ? ARG4 : "XPerl compact hash layouts: OA versus SC"
set multiplot layout 2,1 title plot_title font ",16"
set logscale x
set xtics ("8" 8, "16" 16, "100" 100, "1k" 1000, "10k" 10000, "100k" 100000, "300k" 300000)
set grid ytics lc rgb "#dddddd"
set border 3
set tics nomirror
set key outside top center horizontal maxrows 2 font ",10"
set xlabel "Live entries"
set ylabel "OA / SC elapsed time"
stat_label = exists("ARG5") ? ARG5 : "Paired median ratios"
set title stat_label . " with bootstrap intervals; below 1 favors OA"
plot ARG1 using 1:5:6:7 with yerrorlines lw 2 pt 7 lc rgb "#007f7b" title "Random fetch", \
     ARG1 using 1:8:9:10 with yerrorlines lw 2 pt 5 lc rgb "#8053c4" title "Shared-key fetch", \
     ARG1 using 1:11:12:13 with yerrorlines lw 2 pt 9 lc rgb "#c65b18" title "Churn", \
     ARG1 using 1:14:15:16 with yerrorlines lw 2 pt 11 lc rgb "#3366aa" title "Construct + destroy", \
     ARG1 using 1:17:18:19 with yerrorlines lw 2 pt 6 lc rgb "#a72d40" title "Miss lookup", \
     1 with lines dt 2 lc rgb "#777777" title "Equal time"
set ylabel "OA / SC requested table bytes"
set title "Initial populated storage, including allocated capacity; below 1 favors OA"
plot ARG1 using 1:2 with linespoints lw 2 pt 7 lc rgb "#007f7b" title "Requested storage", \
     1 with lines dt 2 lc rgb "#777777" title "Equal storage"
unset multiplot
