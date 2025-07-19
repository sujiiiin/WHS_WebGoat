#!/bin/bash
set -e


echo "[🧪 DEBUG] PATH에 SonarScanner 추가"
export PATH=$PATH:/opt/sonar-scanner/bin

SCANNER_HOME="/opt/sonar-scanner/bin/sonar-scanner"
echo "[🧪 DEBUG] SonarScanner 경로: $SCANNER_HOME"

echo "[*] Maven compile + dependency 복사"
MVN_HOME=$(which mvn)
$MVN_HOME compile dependency:copy-dependencies -DoutputDirectory=target/dependency -DskipTests

# 🧪 SonarQube 분석
echo "[*] SonarQube 분석 시작..."
export NODE_OPTIONS=--max_old_space_size=4096
$SCANNER_HOME \
  -Dsonar.projectKey=webgoat \
  -Dsonar.sources=. \
  -Dsonar.java.binaries=target/classes \
  -Dsonar.java.libraries=target/dependency/*.jar \
  -Dsonar.python.version=3.9 \
  -Dsonar.token=$SONAR_AUTH_TOKEN

timestamp=$(date +%F_%H-%M-%S)
REPORT_FILE="sonar_issues_${timestamp}.json"

echo "[*] 분석 결과 파일 저장 중: $REPORT_FILE"
curl -s -H "Authorization: Bearer $SONAR_AUTH_TOKEN" \
     "$SONAR_HOST_URL/api/issues/search?componentKeys=webgoat&statuses=OPEN,REOPENED,CONFIRMED&ps=500" \
     -o "$REPORT_FILE"

S3_BUCKET="ss-bucket-0305"
echo "[*] S3 업로드 시작..."
aws s3 cp "$REPORT_FILE" "s3://${S3_BUCKET}/sonarqube-reports/$REPORT_FILE" --region ap-northeast-2 && \
  echo "✅ S3 업로드 완료" || echo "⚠️ S3 업로드 실패 (무시)"

echo "[✔] SonarQube 분석 → API → S3 전 과정 완료"
