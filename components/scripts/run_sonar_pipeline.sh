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

# 🧪 DYNAMIC_IMAGE_TAG 삽입
if [[ -n "$DYNAMIC_IMAGE_TAG" && -f "$REPORT_FILE" ]]; then
  tmp_file="${REPORT_FILE}.tmp"
  jq --arg tag "$DYNAMIC_IMAGE_TAG" '. + {imageTag: $tag}' "$REPORT_FILE" > "$tmp_file" && mv "$tmp_file" "$REPORT_FILE"
  echo "[🧪 DEBUG] imageTag 삽입 완료: $DYNAMIC_IMAGE_TAG"
else
  echo "[⚠️] DYNAMIC_IMAGE_TAG가 비어있거나 JSON 파일이 존재하지 않음"
fi

S3_BUCKET="sonarqube-sast-bucket-wh-whs"
echo "[*] S3 업로드 시작..."
aws s3 cp "$REPORT_FILE" "s3://${S3_BUCKET}/sonarqube-reports/$REPORT_FILE" --region ap-northeast-2 && \
  echo "✅ S3 업로드 완료" || echo "⚠️ S3 업로드 실패 (무시)"

echo "[✔] SonarQube 분석 → API → S3 전 과정 완료"
