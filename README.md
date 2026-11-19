# VoiceGuard (iOS)

주변 대화의 **감정 격양(성량 급등 · 피치 상승 · 에너지 급변)**을 100% 온디바이스로 감지해, 격양 직전 **프리롤(기본 5초)**부터 자동으로 녹음을 시작·저장하는 iOS 앱 프로젝트입니다.

## 주요 구조

- `Packages/VoiceGuardCore`: 순수 Swift DSP·상태 머신 코어 (`AudioFeatureExtractor`, `AgitationDetector`, `PreRollRingBuffer`, `RecordingSessionRecord`)
- `App/`: SwiftUI 앱 (`MonitorView`, `RecordingsListView`, `SettingsAndPrivacyView`) 및 `AVAudioEngine` / `AVAudioFile` 실시간 녹음 서비스
- `Tests/`: Swift 단위 테스트
- `scripts/verify_dsp.py`: 알고리즘 시나리오 검증 스크립트
- `docs/APP_STORE_LAUNCH_GUIDE.md`: 실제 App Store 서비스 출시 로드맵 및 심사 대응 가이드

## 맥북에서 바로 실행하기

> 참고: 본 프로젝트는 Linux 환경에서 작성되어 `xcodebuild` 컴파일 및 iOS 시뮬레이터 실행은 맥북 Xcode에서 진행해야 합니다.

```bash
brew install xcodegen
xcodegen generate
open VoiceGuard.xcodeproj
```

Xcode에서 **Signing & Capabilities**에 본인 Apple Developer 팀을 선택한 뒤 실제 iPhone(마이크 테스트는 실기기 권장)에서 실행하면 됩니다.
