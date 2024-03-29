#!/bin/bash

# Author: Eyal Zohar
# Version: 3
# Notes: Bootstrap logs are in "/mnt/var/log/bootstrap-actions/1/"

# Where to put all apps and config files that are later used by driver and/or executors
PROFILER_FOLDER=/opt/profiler
# The target influxdb host address
INFLUX_HOST=influxdb.eyalzo.com

# Get Arguments
while [ $# -gt 0 ]
do
  case "$1" in
    -d|--profiler-folder)
      shift; PROFILER_FOLDER=$1; shift;;
    -i|--influx-host)
      shift; INFLUX_HOST=$1; shift;;
    -*)
      echo "Unrecognized option: $1";;
    *)
      break;
      ;;
  esac
  shift
done

sudo mkdir -p $PROFILER_FOLDER
aws s3 cp s3://cluster-bootstrap/cluster-bootstrap.sh $PROFILER_FOLDER

### Install Uber JVM Profiler on EMR machines (AMI 2)

# Install git and maven
sudo yum -y install git-core
sudo yum -y install maven
# Install htop that shows each core's effort
sudo yum -y install htop

# Learn more at https://aws.amazon.com/amazon-linux-2/faqs/#Amazon_Linux_Extras
sudo amazon-linux-extras install -y collectd
# Note the tricky use of variable - use the " around variable so it will be converted, surround with ' and then " to be printed
sudo sed -i 's/#LoadPlugin network/LoadPlugin network\n<Plugin network>\n  Server "'"$INFLUX_HOST"'" "25826"\n<\/Plugin>/g' /etc/collectd.conf
# Aggregation is no longer required because "cpu" has a "ReportByCpu false" option
#sudo sed -i 's/#LoadPlugin aggregation/LoadPlugin aggregation\n<Plugin aggregation>\n  <Aggregation>\n    Plugin "cpu"\n    Type "cpu"\n    GroupBy "Host"\n    GroupBy "TypeInstance"\n    CalculateAverage true\n  <\/Aggregation>\n<\/Plugin>/g' /etc/collectd.conf
sudo sed -i 's/#<Plugin cpu>/<Plugin cpu>\n  ReportByCpu false\n  ReportByState true\n<\/Plugin>/g' /etc/collectd.conf
sudo sed -i 's/#LoadPlugin disk/LoadPlugin disk/g' /etc/collectd.conf
#sudo sed -i 's/#LoadPlugin df/LoadPlugin df\n<Plugin df>\n  MountPoint "\/mnt\/hdfs"\n<\/Plugin>/g' /etc/collectd.conf
sudo sed -i 's/#LoadPlugin df/LoadPlugin df/g' /etc/collectd.conf
sudo sed -i 's/#LoadPlugin uptime/LoadPlugin uptime/g' /etc/collectd.conf
sudo sed -i 's/#LoadPlugin tcpconns/LoadPlugin tcpconns\n<Plugin "tcpconns">\n  AllPortsSummary true\n<\/Plugin>/g' /etc/collectd.conf
sudo sed -i 's/#Interval     10/Interval     1/g' /etc/collectd.conf
sudo systemctl restart collectd

# Clone the profiler and build it
git clone https://github.com/uber-common/jvm-profiler.git
cd jvm-profiler/
# Add support to influxdb, as an optional reporter with Grafana (CPU, memory, IO)
mvn -P influxdb clean package

# Copy to the profiler folder and set permissions
sudo cp target/jvm-profiler-1.0.0.jar /opt/profiler/.
sudo chown hadoop:hadoop /opt/profiler/ -R
chmod +x /opt/profiler/jvm-profiler-1.0.0.jar

### Prepare influxdb configuration

# Prepare the config file with default influxdb settings
PROFILER_CONFIG="$PROFILER_FOLDER/influxdb.yaml"
echo "influxdb:" > $PROFILER_CONFIG
echo "  host: ${INFLUX_HOST}" >> $PROFILER_CONFIG
echo "  port: 8086" >> $PROFILER_CONFIG
echo "  database: metrics" >> $PROFILER_CONFIG
echo "  username: admin" >> $PROFILER_CONFIG
echo "  password: admin" >> $PROFILER_CONFIG

### Install Data Bricks TPC-DS Toolkit

# The script that build the jar is in databricks-sql-perf-install.sh
# The build takes ~5 minutes, so we better copy from s3 after one-time build
aws s3 cp s3://cluster-bootstrap/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar $PROFILER_FOLDER
for i in `ls -d $PROFILER_FOLDER/spark-sql-perf_*.jar`; do sudo chmod +x $i;done

# Get dsdgen
# The original dsdgen (from the TPC-DS toolkit) does not work as expected (version 2.4+), because it does not print to stdout. Therefore, it is required to perform the following:
cd /opt/profiler
sudo yum install -y gcc make flex bison byacc git
git clone https://github.com/databricks/tpcds-kit.git databricks-tpcds-kit
cd databricks-tpcds-kit/tools
make clean
make OS=LINUX

ls -la $PROFILER_FOLDER