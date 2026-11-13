# imc_report.tcl - summary and detailed reports of the merged coverage
load -run cov_work/scope/merged
report -summary -inst -metrics all -out reports/summary.txt
report -detail -metrics covergroup -cumulative on -out reports/functional_detail.txt
report -detail -metrics assertion -out reports/assertions.txt
exit
