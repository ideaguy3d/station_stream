#!/bin/zsh
# Per-minute CloudWatch table for app 2 during a load-test window.
#   loadtest/metrics.sh 2026-10-09T06:00:00Z 2026-10-09T06:20:00Z
# Columns: ECS CPU % (avg/max across tasks), healthy targets, ALB requests, requests per target,
# target response time (avg ms), target 5xx, load-balancer 5xx, Aurora ACU.
set -e
export AWS_PROFILE=${AWS_PROFILE:-station-stream} AWS_REGION=${AWS_REGION:-us-east-1}
START=$1 END=$2
LB=$(aws elbv2 describe-load-balancers --names station-stream-tf-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text | sed 's#.*:loadbalancer/##')
TG=$(aws elbv2 describe-target-groups --names station-stream-tf-tg --query 'TargetGroups[0].TargetGroupArn' --output text | sed 's#.*:##')

q() { # id namespace metric stat dims...
  local id=$1 ns=$2 m=$3 st=$4; shift 4
  local dims=""; for d in "$@"; do dims+="{\"Name\":\"${d%%=*}\",\"Value\":\"${d#*=}\"},"; done
  echo "{\"Id\":\"$id\",\"MetricStat\":{\"Metric\":{\"Namespace\":\"$ns\",\"MetricName\":\"$m\",\"Dimensions\":[${dims%,}]},\"Period\":60,\"Stat\":\"$st\"}}"
}
QUERIES="[$(q cpuavg AWS/ECS CPUUtilization Average ClusterName=station-stream-tf ServiceName=api),
$(q cpumax AWS/ECS CPUUtilization Maximum ClusterName=station-stream-tf ServiceName=api),
$(q healthy AWS/ApplicationELB HealthyHostCount Maximum LoadBalancer=$LB TargetGroup=$TG),
$(q reqs AWS/ApplicationELB RequestCount Sum LoadBalancer=$LB),
$(q reqpt AWS/ApplicationELB RequestCountPerTarget Sum LoadBalancer=$LB TargetGroup=$TG),
$(q rt AWS/ApplicationELB TargetResponseTime Average LoadBalancer=$LB),
$(q t5xx AWS/ApplicationELB HTTPCode_Target_5XX_Count Sum LoadBalancer=$LB),
$(q e5xx AWS/ApplicationELB HTTPCode_ELB_5XX_Count Sum LoadBalancer=$LB),
$(q acu AWS/RDS ServerlessDatabaseCapacity Maximum DBClusterIdentifier=station-stream-tf-db)]"

aws cloudwatch get-metric-data --start-time $START --end-time $END --metric-data-queries "$QUERIES" --output json |
python3 -c '
import json,sys
from datetime import datetime,timezone
utc=lambda t: datetime.fromisoformat(t).astimezone(timezone.utc).strftime("%H:%M")
r={m["Id"]:dict(zip(m["Timestamps"],m["Values"])) for m in json.load(sys.stdin)["MetricDataResults"]}
ts=sorted(set().union(*[set(v) for v in r.values()]))
cols=["cpuavg","cpumax","healthy","reqs","reqpt","rt","t5xx","e5xx","acu"]
print("time(UTC) " + " ".join(f"{c:>7}" for c in cols))
for t in ts:
    row=[]
    for c in cols:
        v=r[c].get(t)
        row.append("      -" if v is None else (f"{v*1000:7.0f}" if c=="rt" else f"{v:7.1f}"))
    print(utc(t) + "     " + " ".join(row))
'
