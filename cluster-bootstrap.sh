#!/bin/bash

# Author: Eyal Zohar
# Version: 2
# Notes: Bootstrap logs are in "/mnt/var/log/bootstrap-actions/1/"

PROFILER_FOLDER=/opt/profiler
aws s3 cp s3://cluster-bootstrap/cluster-bootstrap.sh $PROFILER_FOLDER

### Install Uber JVM Profiler on EMR machines (AMI 2)

# Install git and maven
sudo yum -y install git-core
sudo yum -y install maven

# Clone the profiler and build it
git clone https://github.com/uber-common/jvm-profiler.git
cd jvm-profiler/
# Add support to influxdb, as an optional reporter with Grafana (CPU, memory, IO)
mvn -P influxdb clean package

# Copy to the profiler folder and set permissions
sudo mkdir $PROFILER_FOLDER
sudo cp target/jvm-profiler-1.0.0.jar /opt/profiler/.
sudo chown hadoop:hadoop /opt/profiler/ -R
chmod +x /opt/profiler/jvm-profiler-1.0.0.jar

### Prepare influxdb configuration

# Change this to your influxdb host address
if [ -z "$INFLUX_HOST" ]; then
  INFLUX_HOST=18.196.147.58;
fi

# Prepare the config file with default influxdb settings
PROFILER_CONFIG="$PROFILER_FOLDER/influxdb.yaml"
echo "influxdb:" > $PROFILER_CONFIG
echo "  host: ${INFLUX_HOST}" >> $PROFILER_CONFIG
echo "  port: 8086" >> $PROFILER_CONFIG
echo "  database: metrics" >> $PROFILER_CONFIG
echo "  username: admin" >> $PROFILER_CONFIG
echo "  password: admin" >> $PROFILER_CONFIG

### Install Data Bricks TPC-DS Toolkit

# Install SBT
curl https://bintray.com/sbt/rpm/rpm | sudo tee /etc/yum.repos.d/bintray-sbt-rpm.repo
sudo yum -y install sbt

# Build spark-sql-perf
git clone https://github.com/databricks/spark-sql-perf ~/databricks-spark-sql-perf
cd ~/databricks-spark-sql-perf
sudo sbt +package

# Get dsdgen
# The original dsdgen (from the TPC-DS toolkit) does not work as expected (version 2.4+), because it does not print to stdout. Therefore, it is required to perform the following:
git clone https://github.com/databricks/tpcds-kit.git ~/databricks-tpcds-kit
cd ~/databricks-tpcds-kit/tools
# You may need this on a brand new machine:
# sudo apt install -y gcc make flex bison byacc
make

# Copy the runable files
cp ~/databricks-spark-sql-perf/target/scala-2.12/*.jar "$PROFILER_FOLDER"
cp ~/databricks-tpcds-kit/tools/dsdgen "$PROFILER_FOLDER"
ls -la "$PROFILER_FOLDER"