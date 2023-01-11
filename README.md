# Openshift Container Platform Activity Reporter

This project generates some usage statistics about the usage of an OCP cluster
collecting and analyzing the available audit logs.

It's important to highlight that the scope of the analysis depends of the
amount of logs stored by the cluster based on its logging operator configuration

## Usage
To obtain the result it's important to follow a few steps

Before continue, ensure yourself that your OC CLI is connected properly to the
cluster that you want to analyze.

### Collecting logs
First of all to collect the logs is required. This will speed up the statistics
analysis and also prevents the OCP's API abuse.
```sh
./auditor.sh -c
```
This will store the available logs at: `logs/<CLUSTER_DOMAIN>/`


### Analyzing logs
Once the logs are collected, run the following command:
```sh
./auditor.sh -s
```
**NOTE:** This could take some time, depending of the logs size. Be patient.


### Results
The script creates a folder in `stats/<CLUSTER_DOMAIN>/` to store the results of
the analysis. The generated stats files are:
1. JSON file containing the stats values
2. A PNG graph generated with gnuplot about how many actions per user are
   registered. Image: `stats/<CLUSTER_DOMAIN>/<CLUSTER_DOMAIN>-user.png`
3. A PNG graph generated with gnuplot about how many actions per verb are
   registered. Image: `stats/<CLUSTER_DOMAIN>/<CLUSTER_DOMAIN>-user.png`


### Getting help
```sh
./auditor.sh -h
#> ./auditor.sh
#>   -c: Collects every Audit log
#>   -s: Process the collected logs and extract the available stats
#>   -h: Prints script's usage
```
