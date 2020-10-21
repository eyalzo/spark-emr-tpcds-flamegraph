#!/bin/bash

# Author: Eyal Zohar
# Version: 2

PROFILER_FOLDER=/opt/profiler
sudo mkdir $PROFILER_FOLDER

sudo yum -y install git-core

### Install Data Bricks TPC-DS Toolkit

# Install SBT
curl https://bintray.com/sbt/rpm/rpm | sudo tee /etc/yum.repos.d/bintray-sbt-rpm.repo
sudo yum -y install sbt

# Build spark-sql-perf
git clone https://github.com/databricks/spark-sql-perf $PROFILER_FOLDER/databricks-spark-sql-perf
cd $PROFILER_FOLDER/databricks-spark-sql-perf
# This one takes several minutes, so we might have to build it once and copy it here from s3 in the future
sudo sbt +package
# Copy the jar to our folder
cp $PROFILER_FOLDER/databricks-spark-sql-perf/target/scala-2.12/spark-sql-perf_*.jar $PROFILER_FOLDER
for i in `ls -d $PROFILER_FOLDER/spark-sql-perf_*.jar`; do sudo chmod +x $i;done
# For a future "copy from s3 instead of build": aws s3 cp $PROFILER_FOLDER/spark-sql-perf_*.jar s3://cluster-bootstrap/

ls -la $PROFILER_FOLDER