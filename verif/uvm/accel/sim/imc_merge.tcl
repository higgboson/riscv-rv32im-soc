# imc_merge.tcl - merge every coverage run of the regression into cov_work/scope/merged
merge cov_work/scope/* -out merged -overwrite -initial_model union_all
exit
