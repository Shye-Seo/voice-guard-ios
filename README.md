# VoiceGuard (iOS)

주변 대화의 **감정 격양(성량 급등 · 피치 상승 · 에너지 급변)**을 100% 온디바이스로 감지해, 격양 직전 **프리롤(기본 5초)**부터 자동으로 녹음을 시작·저장하는 iOS 앱 프로젝트입니다.

## 주요 구조

- `Packages/VoiceGuardCore`: 순수 Swift DSP·상태 머신 코어
  - `TwoStageVAD` — 1단계 저전력 에너지 게이트 + 2단계 스펙트럴/피치 분석 파이프라인, 배터리 절약 통계
  - `AudioFeatures` — RMS dB · ZCR · Spectral Flux · 자기상관 F0 추출기
  - `AgitationDetector` — 적응형 베이스라인 · 히스테리시스 상태 머신
  - `AgitationTimeline` — 격양 구간 누적기(이벤트 병합) · 세션 피크/엔벨로프 누적기
  - `PreRollRingBuffer` · `RecordingSessionModels`(분석 메타데이터 + 하위 호환 디코딩)
- `App/`
  - `Services/AudioMonitorService` — 2-Stage VAD 파이프라인, 인터럽션·경로 변경·미디어 서비스 리셋 자동 복구
  - `Services/AppLockService` — Face ID / Touch ID / 기기 암호 앱 잠금
  - `Services/RecordingStore` — `completeUnlessOpen` 파일 암호화, 목록·재생·공유
  - `Views/MonitorView`, `RecordingsListView`, `RecordingDetailView`, `AgitationTimelineView`, `SettingsAndPrivacyView`, `AppLockGateView`
- `Tests/`, `Packages/VoiceGuardCore/Tests/`: Swift 단위 테스트 (코어 17개)
- `scripts/verify_dsp.py`: DSP 시나리오 검증 스크립트 (10개 시나리오)
- `docs/ARCHITECTURE.md`: 2-Stage VAD · 복구 매트릭스 · 보안 계층 설계
- `docs/APP_STORE_LAUNCH_GUIDE.md`: 실제 App Store 서비스 출시 로드맵 및 심사 대응 가이드

## v1.1에서 추가된 것

1. **2-Stage VAD**: 샘플 1/4 서브샘플 RMS로 게이트를 열고, 게이트를 통과한 프레임만 자기상관 피치·스펙트럴 분석을 수행합니다. 야간 1시간 시뮬레이션 기준 2단계 분석 비율 5.1%(절약 추정 93.3%), 낮 거실 10분 기준 27.8%(71.0%)입니다.
2. **세션 복구**: 전화·알람 인터럽션, 에어팟 연결/해제, 미디어 서비스 리셋, 엔진 구성 변경 시 자동 재시작(디바운스 + 최대 3회 재시도).
3. **녹음 보안**: 모든 녹음과 `index.json`에 `FileProtectionType.completeUnlessOpen`, 앱 잠금(Face ID/Touch ID/기기 암호), 백그라운드 자동 잠금.
4. **격양 타임라인 · 리포트**: 피크 dB · 최대 F0 · 격양 구간 타임스탬프를 저장하고, 상세 화면에서 Canvas 타임라인·이벤트 목록·리포트 텍스트·m4a 공유를 제공합니다.

## 검증 상태

| 대상 | 방법 | 결과 |
| --- | --- | --- |
| `VoiceGuardCore` | Linux Swift 6.0.3 실제 컴파일 + XCTest | 17/17 통과 |
| DSP 시나리오 | `python3 scripts/verify_dsp.py` | 10/10 통과 |
| 앱 타깃(SwiftUI·AVFoundation) | Linux 환경이라 타입 체크 불가, `swiftc -parse` 구문 검증만 | **Xcode 실기기 빌드 미검증** |

```bash
python3 scripts/verify_dsp.py
# Swift 코어 테스트는 macOS에서
swift test --package-path Packages/VoiceGuardCore
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
