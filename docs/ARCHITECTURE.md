# VoiceGuard 아키텍처

실서비스 출시를 목표로 한 v1.1 구조. 4개 축(배터리·복구 / 녹음 보안 / 분석 리포트 / 검증)으로 나뉜다.

## 1. 2-Stage VAD (배터리 · 백그라운드 생존성)

```
AVAudioEngine input tap (2048 samples @48kHz ≈ 42.6ms)
        │
        ▼
┌──────────────────────────────┐
│ Stage 1 · 에너지 게이트       │  샘플 1/4만 사용하는 서브샘플 RMS(dB) + 저비용 ZCR
│  TwoStageVADAnalyzer         │  프레임당 ~1천 연산
└──────────────┬───────────────┘
               │ 게이트 열림? (배경 소음 + enter margin, 히스테리시스 hold)
               ├── 아니오 ──▶ 경량 프레임(features: rms, zcr / pitch=0, flux=0)
               │                + 20프레임(약 1초)마다 프로브 1회
               ▼ 예
┌──────────────────────────────┐
│ Stage 2 · 스펙트럴/피치 분석   │  AudioFeatureExtractor: ZCR · Spectral Flux ·
│  AudioFeatureExtractor        │  자기상관 F0 (534 lag × 2048 ≈ 109만 MAC)
└──────────────┬───────────────┘
               ▼
      AgitationDetector (적응형 베이스라인 · 히스테리시스 상태 머신)
               ▼
   RecordingSessionAccumulator (피크 dB · 최대 F0 · 격양 구간 · 음량 엔벨로프)
```

핵심 설계 근거

- **게이트 임계 < 트리거 임계**: `TwoStageVADConfiguration.recommended(for:)`는 게이트 진입 마진을
  `requiredDeltaDB - 2dB`로 잡는다. 게이트가 닫힌 프레임은 감지기의 `deltaDB >= requiredDeltaDB`
  조건을 만족할 수 없으므로, 2단계 분석을 건너뛴 프레임에서 오탐이 발생하지 않는다(테스트로 고정).
- **프로브 프레임**: 게이트가 닫혀 있어도 1초에 한 번은 2단계 분석을 수행해 배경 소음 추종과
  피치 기준선 갱신이 끊기지 않게 한다. 그 대가로 최소 5% 수준의 2단계 분석이 항상 발생한다.
- **배경 소음은 게이트가 닫힌 프레임에서만 추종**: TV를 계속 틀어둔 환경처럼 소리가 계속 큰
  경우 게이트가 열린 채 유지된다. 절약보다 "감지 누락 없음"을 우선한 의도적 트레이드오프이며,
  `scripts/verify_dsp.py`의 10번 시나리오가 이 동작을 문서화한다.
- **비용 모델**: `TwoStageVADStats.estimatedBatterySavingsPercent`는 2단계 프레임 비용을 1단계의
  60배로 잡은 **연산량 모델**이다(실제 자기상관/1단계 비율은 약 1000배). 실측 전력량이 아니므로
  UI에도 "추정"으로 표기한다.

## 2. 세션 복구 (AudioSession / 엔진)

| 이벤트 | 처리 | 결과 |
| --- | --- | --- |
| `interruptionNotification` .began (전화·알람) | 진행 중 녹음 확정 저장 → 탭 제거 → 엔진 정지 | `isSuspendedBySystem = true`, 안내 문구 표시 |
| `interruptionNotification` .ended | 250ms 지연 후 세션 재활성 + 엔진 재시작 | `shouldResume` 여부와 무관하게 재개 시도 |
| `routeChangeNotification` .newDeviceAvailable | 세션 재설정 + 엔진 재시작 | 에어팟 연결 시 입력 포맷 재수집 |
| `routeChangeNotification` .oldDeviceUnavailable | 위와 동일 | 내장 마이크로 전환 |
| `routeChangeNotification` .categoryChange/.override/.wakeFromSleep 등 | 위와 동일 | 경로 변경 대응 |
| `mediaServicesWereResetNotification` | 세션 재활성 + 엔진 재시작 | 미디어 서비스 리셋 복구 |
| `AVAudioEngineConfigurationChange` | 세션 재설정 + 엔진 재시작 | 엔진 구성 변경 대응 |

- 복구 요청은 0.6초 디바운스로 중복을 막고, 실패 시 1.5초 간격으로 최대 3회 재시도한다.
- 실패가 누적되면 감지를 중지하고 사용자에게 오류를 노출한다(무한 재시도 방지).
- 파일을 연 채 입력 포맷이 바뀌면 오디오가 손상되므로, 복구 직전에 항상 진행 중인 녹음을 확정 저장한다.
- 세션 재활성·엔진 재시작은 모두 메인 액터에서 수행하고, 오디오 탭 콜백은 분석기만 사용한다
  (`TwoStageVADAnalyzer`는 내부 `NSLock`으로 스레드 안전).

## 3. 녹음 보안

| 계층 | 구현 | 효과 |
| --- | --- | --- |
| 파일 암호화 | `RecordingStore`가 모든 `.m4a`와 `index.json`에 `FileProtectionType.completeUnlessOpen` 적용 (신규 생성 시 + 기존 파일 마이그레이션) | 기기 잠금 시 복호화 키가 메모리에서 내려감 |
| 앱 잠금 | `AppLockService`(`LocalAuthentication`, `.deviceOwnerAuthentication`) | Face ID / Touch ID / 기기 암호로 녹음함 전체 잠금 |
| 자동 잠금 | 백그라운드 진입 시 `lockIfNeeded()` | 앱 전환기 스냅샷·복귀 시 인증 요구 |
| 화면 가림 | `AppLockGateView`가 탭 전체를 덮음 | 잠금 상태에서 목록·재생·공유 접근 불가 |

- 잠금 설정 변경(켜기/끄기)은 매번 본인 확인을 요구한다.
- 생체 인증이 없거나 잠긴 경우 기기 암호로 폴백하고, 실패 사유를 한국어로 안내한다.
- `NSFaceIDUsageDescription`을 `project.yml` Info 속성에 추가했다.

## 4. 격양 타임라인 · 리포트

- `AgitationTimelineAccumulator`: 프레임 판정을 받아 `mergeGapSeconds`(기본 1초) 이내 진정 구간을
  같은 이벤트로 병합하고, 이벤트별 피크(격양도·dB·F0)와 프레임 수를 기록한다.
- `RecordingSessionAccumulator`: 피크/평균 dB, 최대 F0, 격양 구간, 0.5초 버킷 음량 엔벨로프를 모아
  `SessionAnalysisSummary`로 확정한다.
- `RecordingSessionRecord`에 메타데이터 필드를 추가하되 `decodeIfPresent` 기반 커스텀 디코더로
  **v1.0 index.json과 하위 호환**을 유지한다(구버전 레코드는 `hasAnalysisMetadata == false`).
- `RecordingDetailView` + `AgitationTimelineView`: Canvas로 음량 엔벨로프와 격양 구간 밴드를 그리고,
  이벤트 목록·지표·메모·m4a 공유/내보내기(`ShareLink`)·리포트 텍스트 공유/복사를 제공한다.

## 5. 검증 범위

| 대상 | 방법 | 결과 |
| --- | --- | --- |
| `VoiceGuardCore` (DSP·상태 머신·타임라인·모델) | Linux Swift 6.0.3 툴체인으로 실제 컴파일 + XCTest 실행 | 17개 테스트 통과 |
| DSP 시나리오 (게이트·배터리·오탐·메타데이터) | `scripts/verify_dsp.py` (Swift 수식 미러) | 10개 시나리오 통과 |
| App 계층 (SwiftUI · AVFoundation · LocalAuthentication) | Linux에서 프레임워크 부재로 타입 체크 불가 → `swiftc -parse` 구문 검증 + 코드 리뷰 | 구문 오류 0건, **타입 체크·실기기 빌드 미검증** |

App 계층은 Xcode 15.4/iOS 17 실기기에서 첫 빌드 시 다음을 확인해야 한다.

1. `AVAudioSession` 인터럽션/경로 변경 복구가 실제 통화·에어팟 전환에서 동작하는지
2. `FileProtectionType.completeUnlessOpen`이 실제 파일에 적용되는지(설정 화면 "보호된 녹음 파일" 개수)
3. Face ID 잠금 화면과 `ShareLink` 공유 시트가 잠금 상태에서 노출되지 않는지
4. 배터리 소모 실측(야간 8시간 / 낮 4시간)과 게이트 절약 추정치의 방향성 일치 여부
