//최소정책기준탐지 반영ver
#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_java_version() {
    local REPO_NAME="$1"
    local VERSION="$2"   # ← 이름 변경

    echo "[+] 언어 및 Java 버전 탐지 시작"
    cd "/tmp/${REPO_NAME}_${BUILD_ID}" || exit 1

    IMAGE_TAG="cli"
    JAVA_VERSION=""
    BUILD_FILE=""

    if [[ -f "pom.xml" ]]; then
        echo "[🔍] pom.xml 감지됨 – Java Maven 프로젝트"
        BUILD_FILE="pom.xml"
    elif [[ -f "build.gradle.kts" ]]; then
        echo "[🔍] build.gradle.kts 감지됨 – Java Gradle(Kotlin DSL) 프로젝트"
        BUILD_FILE="build.gradle.kts"
    elif [[ -f "build.gradle" ]]; then
        echo "[🔍] build.gradle 감지됨 – Java Gradle 프로젝트"
        BUILD_FILE="build.gradle"
    fi

    if [[ -n "$BUILD_FILE" ]]; then
        JAVA_VERSION=$(python3 "$SCRIPT_DIR/pom_to_docker_image.py" "$BUILD_FILE" 2>/dev/null | tr -d '\r')
        if [[ -z "$JAVA_VERSION" ]]; then
            echo "[⚠️] Bedrock 기반 감지 실패 – 기본 java 사용"
            IMAGE_TAG="java"
        else
            echo "[✅] 감지된 Java 버전: $JAVA_VERSION"
            IMAGE_TAG=$(python3 "$SCRIPT_DIR/docker_tag.py" "$JAVA_VERSION" 2>/dev/null | tr -d '\r')
            [[ -z "$IMAGE_TAG" ]] && IMAGE_TAG="java"
        fi
    elif [[ -f "package.json" || -f "requirements.txt" || -f "pyproject.toml" || -f "go.mod" || -f "Cargo.toml" ]]; then
        echo "[ℹ️] Java 외 언어 프로젝트 감지됨 – CLI 이미지 사용"
        IMAGE_TAG="cli"
        JAVA_VERSION="Not_Java"
    else
        echo "[⚠️] 지원되는 빌드 파일을 감지하지 못함 – 기본(cli) 사용"
        IMAGE_TAG="cli"
        JAVA_VERSION="UNKNOWN"
    fi

    echo "[ℹ️] 최종 선택된 Docker 이미지 태그: $IMAGE_TAG"
    echo "$IMAGE_TAG" > "/tmp/cdxgen_image_tag_${REPO_NAME}_${VERSION}.txt"
    echo "$JAVA_VERSION" > "/tmp/cdxgen_java_version_${REPO_NAME}_${VERSION}.txt"
}

# CVSS 점검 함수
check_cvss() {
    local REPO_NAME="$1"
    local VERSION="$2"

    # CVSS 점검 로직 (Python 스크립트 호출)
    python3 /home/ec2-user/check_cvss.py "$REPO_NAME" "$VERSION" "$DT_URL" || {
        echo "❌ CVSS 9 이상 취약점 발견. SBOM 업로드를 중단합니다."
        return 1
    }

    echo "✅ CVSS 점검 통과"
    return 0
}

# SBOM 업로드 함수
upload_sbom() {
    local REPO_NAME="$1"
    local VERSION="$2"
    local REPO_DIR="$3"
    local COMMIT_ID="$4"

    if [[ -z "$REPO_NAME" || -z "$VERSION" || -z "$REPO_DIR" || -z "$COMMIT_ID" ]]; then
        echo "❌ upload_sbom 함수 호출 시 REPO_NAME, VERSION, REPO_DIR, COMMIT_ID가 필요합니다."
        return 1
    fi

    source /home/ec2-user/.env

    local SBOM_FILE="${REPO_DIR}/sbom_${REPO_NAME}_${VERSION}.json"
    if [[ ! -f "$SBOM_FILE" ]]; then
        echo "❌ SBOM 파일이 존재하지 않습니다: $SBOM_FILE"
        return 1
    fi

    local PROJECT_VERSION="$VERSION"
    echo "🚀 SBOM 업로드 시작: $SBOM_FILE (projectVersion: $PROJECT_VERSION)"

    # CVSS 점검 함수 호출
    check_cvss "$REPO_NAME" "$VERSION" || return 1

    # SBOM 업로드
    curl -X POST http://localhost:8080/api/v1/bom \
        -H "X-Api-Key: $DT_API_KEY" \
        -F "projectName=$REPO_NAME" \
        -F "projectVersion=$PROJECT_VERSION" \
        -F "bom=@$SBOM_FILE" \
        -F "autoCreate=true"
        
    if [[ $? -ne 0 ]]; then
        echo "❌ SBOM 업로드 실패"
        return 1
    fi
    
    # 프로젝트 UUID 조회
    PROJECT_UUID=$(curl -s -X GET "http://localhost:8080/api/v1/project?name=${REPO_NAME}&version=${PROJECT_VERSION}" \
      -H "X-Api-Key: $DT_API_KEY" | jq -r '.[0].uuid')
    
    if [[ -z "$PROJECT_UUID" || "$PROJECT_UUID" == "null" ]]; then
        echo "❌ 프로젝트 UUID를 찾을 수 없습니다."
        return 1
    fi
    
    # 분석 완료까지 대기 (최대 60초), 메시지 없이
    MAX_WAIT=60
    WAITED=0
    while [[ $WAITED -lt $MAX_WAIT ]]; do
        METRICS_JSON=$(curl -s -X GET "http://localhost:8080/api/v1/project/${PROJECT_UUID}" -H "X-Api-Key: $DT_API_KEY")
        VULN_COUNT=$(echo "$METRICS_JSON" | jq '.metrics.vulnerabilities.total' 2>/dev/null)
    
        if [[ "$VULN_COUNT" =~ ^[0-9]+$ ]]; then
            break
        fi
    
        sleep 5
        WAITED=$((WAITED + 5))
    done
    
    # CVSS 9 이상 정책 검사
    echo "📤 CVSS 9 이상 정책 검사 중..."
    python3 /home/ec2-user/check_cvss.py "$PROJECT_UUID" "$DT_API_KEY" "http://localhost:8080" || {
        echo "❌ CVSS 9 이상 취약점 발견. SBOM 업로드를 중단합니다."
        return 1
    }

    echo "✅ CVSS 점검 통과"
}
