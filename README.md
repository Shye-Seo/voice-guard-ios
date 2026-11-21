# VoiceGuard (iOS)

주변 대화의 **감정 격양(성량 급등 · 피치 상승 · 에너지 급변)**을 100% 온디바이스로 감지해, 격양 직전 **프리롤(기본 5초)**부터 자동으로 녹음을 시작·저장하는 iOS 앱 프로젝트입니다.

## 주요 구조

- `Packages/VoiceGuardCore`: 순수 Swift DSP·상태 머신 코어
  - `TwoStageVAD` — 1단계 저전력 에너지 게이트 + 2단계 스펙트럴/피치 분석 파이프라인, 배터리 절약 통계
  - `AudioFeatures` — RMS dB · ZCR · Spectral Flux · 자기상관 F0 추출기
  - `AgitationDetector` — 적응형 베이스라인 · 히스테리시스 상태 머신
  - `AgitationTimeline` — 격양 구간 누적기(이벤트 병합) · 세션 피크/엔벨로프 누적기
  - `SpeechTranscribing` — 온디바이스 STT 추상화(`SpeechTranscriptSegment`·정규화·결정적 `ScriptedSpeechTranscriber`)
  - `AppleSpeechTranscriber` — `SFSpeechRecognizer` 어댑터(온디바이스 강제, 45초 구간 분할 인식)
  - `EpisodeSummarizer` — 전사 세그먼트 ↔ 격양 타임라인 매핑, 핵심 쟁점·키워드·타임라인 마커 요약
  - `PreRollRingBuffer` · `RecordingSessionModels`(분석 메타데이터 + 전사 리포트 + 하위 호환 디코딩)
- `App/`
  - `Services/AudioMonitorService` — 2-Stage VAD 파이프라인, 인터럽션·경로 변경·미디어 서비스 리셋 자동 복구
  - `Services/AppLockService` — Face ID / Touch ID / 기기 암호 앱 잠금
  - `Services/RecordingStore` — `completeUnlessOpen` 파일 암호화, 목록·재생·공유
  - `Services/SpeechTranscriptionService` — 음성 인식 권한·온디바이스 가용성 판정, 전사기 팩토리
  - `Views/MonitorView`, `RecordingsListView`, `RecordingDetailView`, `EpisodeReportView`, `AgitationTimelineView`, `SettingsAndPrivacyView`, `AppLockGateView`
- `Tests/`, `Packages/VoiceGuardCore/Tests/`: Swift 단위 테스트 (코어 45개)
- `scripts/verify_dsp.py`: DSP·요약 시나리오 검증 스크립트 (11개 시나리오)
- `docs/ARCHITECTURE.md`: 2-Stage VAD · 복구 매트릭스 · 보안 계층 설계
- `docs/APP_STORE_LAUNCH_GUIDE.md`: 실제 App Store 서비스 출시 로드맵 및 심사 대응 가이드

## v1.1에서 추가된 것

1. **2-Stage VAD**: 샘플 1/4 서브샘플 RMS로 게이트를 열고, 게이트를 통과한 프레임만 자기상관 피치·스펙트럴 분석을 수행합니다. 야간 1시간 시뮬레이션 기준 2단계 분석 비율 5.1%(절약 추정 93.3%), 낮 거실 10분 기준 27.8%(71.0%)입니다.
2. **세션 복구**: 전화·알람 인터럽션, 에어팟 연결/해제, 미디어 서비스 리셋, 엔진 구성 변경 시 자동 재시작(디바운스 + 최대 3회 재시도).
3. **녹음 보안**: 모든 녹음과 `index.json`에 `FileProtectionType.completeUnlessOpen`, 앱 잠금(Face ID/Touch ID/기기 암호), 백그라운드 자동 잠금.
4. **격양 타임라인 · 리포트**: 피크 dB · 최대 F0 · 격양 구간 타임스탬프를 저장하고, 상세 화면에서 Canvas 타임라인·이벤트 목록·리포트 텍스트·m4a 공유를 제공합니다.

## v1.2에서 추가된 것 — 전사 · 핵심 쟁점 요약

1. **온디바이스 STT 연동**: `SpeechTranscribing` 프로토콜 아래 `SFSpeechRecognizer` 어댑터를 두고, `requiresOnDeviceRecognition = true`를 강제합니다. 기기가 온디바이스 인식을 지원하지 않으면 서버 인식으로 폴백하지 않고 기능을 끕니다(프라이버시 우선). 45초를 넘는 녹음은 최대 8개 구간으로 나눠 순서대로 인식하고 타임스탬프를 원본 시간축으로 되돌립니다.
2. **전사 ↔ 격양 타임라인 매핑**: 전사 세그먼트마다 겹친 격양 이벤트 인덱스·겹침 시간·최고 격양도를 계산합니다(기본 0.2초 이상 겹치면 격양 발화로 판정).
3. **핵심 쟁점 요약**: 가장 격양이 심했던 발화를 핵심 쟁점으로 뽑고, 조사를 떼어낸 반복 키워드(격양 발화 가중 2배), 발화·격양 시간, 타임라인 마커(핵심 쟁점 + 격양 피크)를 한 장의 리포트로 만듭니다. 같은 입력·같은 생성 시각이면 동일한 리포트가 나오도록 식별자도 결정적으로 만듭니다.
4. **리포트 UI**: 상세 화면의 '전사 · 핵심 쟁점 요약' 카드 → `EpisodeReportView`(핵심 발언 카드 · 키워드 칩 · 타임라인 마커 · 격양 구간이 강조된 전사 타임라인 · 공유). 생성된 리포트는 `index.json`에 함께 저장되어 다시 열 때 재전사하지 않습니다.

## 검증 상태

| 대상 | 방법 | 결과 |
| --- | --- | --- |
| `VoiceGuardCore` | Linux Swift 6.0.3 실제 컴파일 + `swift test`(XCTest 45개) | 45/45 통과 |
| DSP · 요약 시나리오 | `python3 scripts/verify_dsp.py` | 11/11 통과 |
| 온디바이스 STT(실제 기기) | `SFSpeechRecognizer` 권한·한국어 모델 필요 | **실기기 미검증**(Linux에서 타입 체크 불가) |
| 앱 타깃(SwiftUI·AVFoundation) | Linux 환경이라 타입 체크 불가, `swiftc -parse` 구문 검증만 | **Xcode 실기기 빌드 미검증** |

```bash
python3 scripts/verify_dsp.py
# Swift 코어 테스트(macOS에서는 그대로 실행)
swift test --package-path Packages/VoiceGuardCore
# Linux 검증 환경에서는 툴체인 sysroot를 SDKROOT로 지정한다
SDKROOT=<sysroot> swift test --package-path Packages/VoiceGuardCore
```

## 맥북에서 바로 실행하기

> 참고: 본 프로젝트는 Linux 환경에서 작성되어 `xcodebuild` 컴파일 및 iOS 시뮬레이터 실행은 맥북 Xcode에서 진행해야 합니다.

```bash
brew install xcodegen
xcodegen generate
open VoiceGuard.xcodeproj
```

Xcode에서 **Signing & Capabilities**에 본인 Apple Developer 팀을 선택한 뒤 실제 iPhone(마이크 테스트는 실기기 권장)에서 실행하면 됩니다.
Face ID 잠금을 쓰려면 기기 암호와 Face ID가 등록되어 있어야 합니다.
