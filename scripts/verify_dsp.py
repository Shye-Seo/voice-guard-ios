#!/usr/bin/env python3
"""
AgitationDetector 수식/히스테리시스 로직의 Python 미러링 검증 스크립트.
조용한 환경 / 일반 대화 / 일시적 단발 소음 / 지속 격양 발화 시나리오를 테스트한다.
"""
from dataclasses import dataclass


@dataclass
class Frame:
    rms_db: float
    zcr: float
    flux: float
    pitch_hz: float


class DetectorMirror:
    def __init__(self, preset: str = "medium", cooldown_s: float = 5.0):
        presets = {
            "low": (0.72, 16.0, 8),
            "medium": (0.58, 11.5, 6),
            "high": (0.45, 8.0, 4),
        }
        self.score_th, self.delta_th, self.consec_req = presets[preset]
        self.cooldown_s = cooldown_s
        self.state = "monitoring"
        self.noise_floor = -55.0
        self.baseline_pitch = 155.0
        self.consec = 0
        self.last_agitated_t = 0.0

    def step(self, f: Frame, t: float):
        if self.state == "monitoring" and f.rms_db < self.noise_floor + 10.0:
            self.noise_floor = self.noise_floor * 0.96 + f.rms_db * 0.04
        if 80 <= f.pitch_hz <= 240 and self.state == "monitoring":
            self.baseline_pitch = self.baseline_pitch * 0.95 + f.pitch_hz * 0.05

        delta_db = max(0.0, f.rms_db - self.noise_floor)
        loud = min(1.0, delta_db / max(1.0, self.delta_th * 1.4))
        pitch_ratio = (
            max(0.0, (f.pitch_hz - self.baseline_pitch) / max(60.0, self.baseline_pitch * 0.65))
            if f.pitch_hz > 0
            else 0.0
        )
        pitch = min(1.0, pitch_ratio)
        flux = min(1.0, f.flux / 0.14)
        zcr = min(1.0, max(0.0, (f.zcr - 0.06) / 0.18))
        score = loud * 0.48 + pitch * 0.24 + flux * 0.18 + zcr * 0.10

        above = score >= self.score_th and delta_db >= self.delta_th
        started = False
        stopped = False

        if self.state == "monitoring":
            if above:
                self.consec += 1
                if self.consec >= self.consec_req:
                    self.state = "recordingAgitated"
                    self.last_agitated_t = t
                    started = True
            else:
                self.consec = max(0, self.consec - 1)
        elif self.state == "recordingAgitated":
            if above or score >= self.score_th * 0.82:
                self.last_agitated_t = t
            else:
                self.state = "cooldown"
        elif self.state == "cooldown":
            if above:
                self.state = "recordingAgitated"
                self.last_agitated_t = t
            elif t - self.last_agitated_t >= self.cooldown_s:
                self.state = "monitoring"
                self.consec = 0
                stopped = True

        return self.state, score, started, stopped


def run_tests():
    # 1. 일반 대화: 오탐 없음
    d = DetectorMirror("medium")
    t = 0.0
    for _ in range(40):
        _, _, started, _ = d.step(Frame(-46.0, 0.05, 0.02, 155.0), t)
        assert not started, "일반 대화에서 오탐 발생"
        t += 0.05

    # 2. 단발성 박수/기침(2프레임): 오탐 없음
    for _ in range(2):
        _, _, started, _ = d.step(Frame(-20.0, 0.20, 0.18, 0.0), t)
        assert not started, "단발 소음에서 오탐 발생"
        t += 0.05
    for _ in range(10):
        d.step(Frame(-52.0, 0.04, 0.01, 0.0), t)
        t += 0.05

    # 3. 지속 격양 발화 -> 녹음 시작 -> 진정 후 자동 종료
    started_any = False
    for _ in range(8):
        _, _, started, _ = d.step(Frame(-18.0, 0.22, 0.16, 290.0), t)
        started_any = started_any or started
        t += 0.05
    assert started_any, "격양 발화에서 녹음 미시작"
    assert d.state == "recordingAgitated"

    stopped_any = False
    for _ in range(120):
        _, _, _, stopped = d.step(Frame(-52.0, 0.04, 0.01, 140.0), t)
        if stopped:
            stopped_any = True
            break
        t += 0.05
    assert stopped_any and d.state == "monitoring", "진정 후 자동 종료 실패"
    print("ALL DSP SCENARIO TESTS PASSED (3/3)")


if __name__ == "__main__":
    run_tests()
