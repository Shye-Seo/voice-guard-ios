#!/usr/bin/env python3
"""
VoiceGuard DSP 시나리오 검증 스크립트.

Linux 환경에서 `xcodebuild`를 쓸 수 없으므로, Swift 구현(`VoiceGuardCore`)의
수식·상태 머신을 1:1로 미러링해 회귀와 신규 기능을 함께 검증한다.

검증 범위
  1) 일반 대화 오탐 없음
  2) 단발성 소음(박수·기침) 오탐 없음
  3) 지속 격양 -> 녹음 시작 -> 진정 후 자동 종료
  4) 2-Stage VAD 1단계 에너지 게이트: 조용한 하루 1시간 시뮬레이션의 2단계 분석 비율 / 배터리 절약
  5) 게이트가 닫힌 프레임은 어떤 민감도에서도 트리거할 수 없음 (property test)
  6) 게이트 히스테리시스(hold) 동작
  7) 세션 메타데이터(피크 dB · 최대 F0 · 격양 구간 병합) 누적
  8) 배경 소음 적응(프라이밍 · 추종)

모든 상수는 `Packages/VoiceGuardCore/Sources/VoiceGuardCore/*.swift`와 동일하게 유지한다.
"""
import re
from dataclasses import dataclass


# ---------------------------------------------------------------------------
# 미러: AgitationDetector
# ---------------------------------------------------------------------------

PRESETS = {
    # (score_threshold, required_delta_db, required_consecutive_frames)
    "low": (0.72, 16.0, 8),
    "medium": (0.58, 11.5, 6),
    "high": (0.45, 8.0, 4),
}


@dataclass
class Frame:
    rms_db: float
    zcr: float = 0.0
    flux: float = 0.0
    pitch_hz: float = 0.0


class DetectorMirror:
    def __init__(self, preset: str = "medium", cooldown_s: float = 5.0):
        self.preset = preset
        self.score_th, self.delta_th, self.consec_req = PRESETS[preset]
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


# ---------------------------------------------------------------------------
# 미러: TwoStageVADAnalyzer (1단계 에너지 게이트)
# ---------------------------------------------------------------------------

STAGE_TWO_COST_MULTIPLIER = 60.0


class TwoStageGateMirror:
    def __init__(
        self,
        preset: str = "medium",
        gate_enter: float = None,
        gate_exit: float = None,
        hold_frames: int = 4,
        probe_interval: int = 20,
        decimation: int = 4,
        absolute_floor_db: float = -62.0,
        noise_adapt_rate: float = 0.04,
    ):
        delta_th = PRESETS[preset][1]
        self.gate_enter = max(4.0, delta_th - 2.0) if gate_enter is None else gate_enter
        self.gate_exit = max(2.0, self.gate_enter - 3.0) if gate_exit is None else min(gate_exit, self.gate_enter)
        self.hold_frames = max(0, hold_frames)
        self.probe_interval = max(1, probe_interval)
        self.decimation = max(1, decimation)
        self.absolute_floor_db = absolute_floor_db
        self.noise_adapt_rate = min(1.0, max(0.001, noise_adapt_rate))

        self.state = "closed"
        self.hold = 0
        self.frames_since_deep = 0
        self.noise_floor = None
        self.total = 0
        self.deep = 0
        self.open = 0

    def step(self, db: float):
        self.total += 1
        if self.noise_floor is None:
            self.noise_floor = db

        enter_th = max(self.noise_floor + self.gate_enter, self.absolute_floor_db)
        exit_th = max(self.noise_floor + self.gate_exit, self.absolute_floor_db - 6.0)

        if self.state == "closed":
            if db >= enter_th:
                self.state = "open"
                self.hold = self.hold_frames
        else:
            if db < exit_th:
                if self.hold > 0:
                    self.hold -= 1
                else:
                    self.state = "closed"
            else:
                self.hold = self.hold_frames

        if self.state == "closed":
            self.noise_floor += (db - self.noise_floor) * self.noise_adapt_rate

        self.frames_since_deep += 1
        is_probe = self.state == "closed" and self.frames_since_deep >= self.probe_interval
        deep = self.state == "open" or is_probe
        if self.state == "open":
            self.open += 1
        if deep:
            self.deep += 1
            self.frames_since_deep = 0
        return self.state, deep

    def features(self, f: Frame, deep: bool) -> Frame:
        """게이트가 닫힌 프레임은 피치/스펙트럴 성분이 0인 경량 특징값을 쓴다."""
        if deep:
            return f
        return Frame(rms_db=f.rms_db, zcr=f.zcr, flux=0.0, pitch_hz=0.0)

    @property
    def deep_ratio(self) -> float:
        return self.deep / self.total if self.total else 0.0

    @property
    def battery_savings_percent(self) -> float:
        if not self.total:
            return 0.0
        light = self.total - self.deep
        used = light * 1.0 + self.deep * STAGE_TWO_COST_MULTIPLIER
        baseline = self.total * STAGE_TWO_COST_MULTIPLIER
        return max(0.0, min(100.0, (1.0 - used / baseline) * 100.0))


# ---------------------------------------------------------------------------
# 미러: RecordingSessionAccumulator / AgitationTimelineAccumulator
# ---------------------------------------------------------------------------


class SessionAccumulatorMirror:
    def __init__(self, merge_gap_s: float = 1.0, extension_ratio: float = 0.82, frame_duration: float = 0.05):
        self.merge_gap_s = merge_gap_s
        self.extension_ratio = extension_ratio
        self.frame_duration = frame_duration
        self.events = []          # list of dicts
        self.peak_rms = -90.0
        self.rms_sum = 0.0
        self.rms_count = 0
        self.max_pitch = 0.0
        self.peak_score = 0.0
        self.open_index = None

    def ingest(self, f: Frame, score: float, state: str, threshold: float, offset: float):
        self.peak_rms = max(self.peak_rms, f.rms_db)
        self.max_pitch = max(self.max_pitch, f.pitch_hz)
        self.peak_score = max(self.peak_score, score)
        self.rms_sum += f.rms_db
        self.rms_count += 1

        is_agitated = state == "recordingAgitated"
        keeps_alive = is_agitated or score >= threshold * self.extension_ratio

        if self.open_index is not None:
            event = self.events[self.open_index]
            gap = offset - event["end"]
            if keeps_alive and gap <= self.merge_gap_s:
                event["end"] = max(event["end"], offset + self.frame_duration)
                event["peak_score"] = max(event["peak_score"], score)
                event["peak_rms"] = max(event["peak_rms"], f.rms_db)
                event["peak_pitch"] = max(event["peak_pitch"], f.pitch_hz)
                event["frames"] += 1
                return
            if gap > self.merge_gap_s:
                self.open_index = None

        if keeps_alive:
            self.events.append(
                {
                    "start": offset,
                    "end": offset + self.frame_duration,
                    "peak_score": score,
                    "peak_rms": f.rms_db,
                    "peak_pitch": f.pitch_hz,
                    "frames": 1,
                }
            )
            self.open_index = len(self.events) - 1

    @property
    def agitated_seconds(self) -> float:
        return sum(max(0.0, e["end"] - e["start"]) for e in self.events)


# ---------------------------------------------------------------------------
# 시나리오
# ---------------------------------------------------------------------------

FRAME_INTERVAL = 0.05  # 20 fps (2048 샘플 @ 48kHz ≈ 42.6ms)


def scenario_calm_conversation():
    d = DetectorMirror("medium")
    t = 0.0
    for _ in range(40):
        _, _, started, _ = d.step(Frame(-46.0, 0.05, 0.02, 155.0), t)
        assert not started, "일반 대화에서 오탐 발생"
        t += FRAME_INTERVAL
    return "일반 대화 오탐 없음 (40프레임)"


def scenario_single_burst():
    d = DetectorMirror("medium")
    t = 0.0
    for _ in range(20):
        d.step(Frame(-46.0, 0.05, 0.02, 155.0), t)
        t += FRAME_INTERVAL
    for _ in range(2):
        _, _, started, _ = d.step(Frame(-20.0, 0.20, 0.18, 0.0), t)
        assert not started, "단발 소음에서 오탐 발생"
        t += FRAME_INTERVAL
    for _ in range(10):
        d.step(Frame(-52.0, 0.04, 0.01, 0.0), t)
        t += FRAME_INTERVAL
    return "단발성 박수/기침 오탐 없음 (2프레임)"


def scenario_sustained_agitation():
    d = DetectorMirror("medium")
    t = 0.0
    for _ in range(10):
        d.step(Frame(-56.0, 0.04, 0.01, 0.0), t)
        t += FRAME_INTERVAL

    started_any = False
    for _ in range(8):
        _, _, started, _ = d.step(Frame(-18.0, 0.22, 0.16, 290.0), t)
        started_any = started_any or started
        t += FRAME_INTERVAL
    assert started_any, "격양 발화에서 녹음 미시작"
    assert d.state == "recordingAgitated"

    stopped_any = False
    for _ in range(160):
        _, _, _, stopped = d.step(Frame(-52.0, 0.04, 0.01, 140.0), t)
        if stopped:
            stopped_any = True
            break
        t += FRAME_INTERVAL
    assert stopped_any and d.state == "monitoring", "진정 후 자동 종료 실패"
    return "지속 격양 -> 자동 녹음 시작 -> 진정 후 자동 종료"


class RunnerMirror:
    """앱 파이프라인 미러: 게이트 -> 감지기 -> (녹음 중일 때만) 세션 누적기."""

    def __init__(self, preset: str = "medium", cooldown_s: float = 12.0):
        self.preset = preset
        self.gate = TwoStageGateMirror(preset)
        self.detector = DetectorMirror(preset, cooldown_s=cooldown_s)
        self.session = SessionAccumulatorMirror()
        self.recording = False
        self.t = 0.0
        self.triggers = 0

    def run(self, seconds, level_fn) -> int:
        frames = int(seconds / FRAME_INTERVAL)
        fired = 0
        for i in range(frames):
            raw = level_fn(i)
            gate_state, deep = self.gate.step(raw.rms_db)
            features = self.gate.features(raw, deep)
            decision_state, score, started, stopped = self.detector.step(features, self.t)
            if started:
                self.triggers += 1
                fired += 1
                self.recording = True
            if self.recording:
                self.session.ingest(features, score, decision_state, PRESETS[self.preset][0], self.t)
            if stopped:
                self.recording = False
            self.t += FRAME_INTERVAL
        return fired


def scenario_battery_night():
    """수면 시간대: 조용한 방에서 드문 소음만 있는 1시간 — 게이트 절약 효과가 가장 큰 조건."""
    runner = RunnerMirror()
    runner.run(600, lambda i: Frame(-60.0 + 0.5 * ((i % 5) - 2), 0.03, 0.004, 0.0))

    # 6분마다 0.2초짜리 문소리/기침 (-45dB)
    for _ in range(10):
        runner.run(0.2, lambda i: Frame(-45.0, 0.18, 0.12, 0.0))
        runner.run(354, lambda i: Frame(-60.0 + 0.5 * ((i % 5) - 2), 0.03, 0.004, 0.0))

    gate = runner.gate
    savings = gate.battery_savings_percent
    assert gate.deep_ratio < 0.08, f"야간 2단계 분석 비율 {gate.deep_ratio:.1%} (기준 8%)"
    assert savings > 92.0, f"야간 배터리 절약 추정 {savings:.1f}% (기준 92%)"
    assert runner.triggers == 0, f"기침/문소리에서 오탐 {runner.triggers}회"
    return (
        f"야간 1시간: 2단계 분석 {gate.deep_ratio:.1%} · 절약 추정 {savings:.1f}% · 오탐 {runner.triggers}회"
    )


def scenario_battery_daytime():
    """낮 거실: 배경 -50dB에 잡담 피크가 섞이다가 3초짜리 격양 발화가 한 번 나오는 10분."""
    runner = RunnerMirror()

    def living_room(i):
        # 30프레임(1.5초) 주기 중 4프레임(0.2초)만 성량이 올라가는 잡담 패턴
        if i % 30 < 4:
            return Frame(-38.0, 0.2, 0.14, 265.0)
        return Frame(-52.0, 0.05, 0.01, 150.0)

    runner.run(540, living_room)
    assert runner.triggers == 0, f"0.2초 잡담 피크에서 오탐 {runner.triggers}회"

    # 3초 지속 격양 발화 — 게이트를 통과해 실제 감지가 동작해야 한다
    fired = runner.run(3, lambda i: Frame(-30.0, 0.22, 0.18, 300.0))
    assert fired == 1, f"지속 격양 발화 감지 {fired}회 (기대 1회)"

    runner.run(60, lambda i: Frame(-52.0, 0.05, 0.01, 150.0))

    gate = runner.gate
    savings = gate.battery_savings_percent
    assert gate.deep_ratio < 0.32, f"낮 거실 2단계 비율 {gate.deep_ratio:.1%} (기준 32%)"
    assert savings > 68.0, f"낮 거실 절약 추정 {savings:.1f}% (기준 68%)"
    assert len(runner.session.events) == 1, f"격양 구간이 {len(runner.session.events)}건으로 기록됨"
    return (
        f"낮 거실 10분: 2단계 분석 {gate.deep_ratio:.1%} · 절약 추정 {savings:.1f}% · "
        f"격양 이벤트 {len(runner.session.events)}건 {runner.session.agitated_seconds:.1f}초"
    )


def scenario_gated_frames_never_trigger():
    """게이트가 닫힌 프레임은 어떤 민감도에서도 트리거 조건을 만족할 수 없다."""
    checked = 0
    for preset in ("low", "medium", "high"):
        gate = TwoStageGateMirror(preset)
        detector = DetectorMirror(preset, cooldown_s=5.0)
        t = 0.0
        enter_margin = gate.gate_enter
        delta_th = PRESETS[preset][1]
        assert enter_margin < delta_th, f"{preset}: 게이트 임계가 트리거 임계보다 높음"

        # 배경 소음 프라이밍
        for _ in range(30):
            gate.step(-55.0)
            detector.step(Frame(-55.0, 0.03, 0.005, 0.0), t)
            t += FRAME_INTERVAL

        # 게이트 임계 바로 아래 ~ 배경 소음 수준의 프레임을 5,000개 흘려보낸다.
        for i in range(5000):
            level = -55.0 + (enter_margin - 0.2) * ((i % 11) / 10.0)
            state, deep = gate.step(level)
            f = gate.features(Frame(level, 0.25, 0.2, 300.0), deep)
            _, _, started, _ = detector.step(f, t)
            if state == "closed":
                checked += 1
                assert not started, f"{preset}: 게이트 닫힘 프레임에서 오탐 발생 (level={level:.1f}dB)"
            t += FRAME_INTERVAL
    return f"게이트 닫힘 프레임 트리거 불가 검증 (3개 민감도 · {checked}프레임)"


def scenario_hysteresis():
    gate = TwoStageGateMirror("medium", gate_enter=9.0, gate_exit=6.0, hold_frames=4)
    for _ in range(20):
        gate.step(-54.0)
    state, _ = gate.step(-20.0)
    assert state == "open", "고음량 프레임에서 게이트가 열리지 않음"

    held = 0
    for _ in range(4):
        state, _ = gate.step(-53.0)
        if state == "open":
            held += 1
    assert held == 4, f"hold 프레임이 {held}/4만 유지됨"
    state, _ = gate.step(-53.0)
    assert state == "closed", "hold 소진 후에도 게이트가 닫히지 않음"
    return "게이트 히스테리시스(hold 4프레임) 동작"


def scenario_session_metadata():
    runner = RunnerMirror(cooldown_s=5.0)
    runner.run(1.0, lambda i: Frame(-52.0, 0.04, 0.01, 140.0))
    runner.run(3.0, lambda i: Frame(-14.0, 0.22, 0.2, 300.0))
    runner.run(10.0, lambda i: Frame(-50.0, 0.04, 0.01, 0.0))

    session = runner.session
    assert session.peak_rms == -14.0, f"피크 dB 오류: {session.peak_rms}"
    assert session.max_pitch == 300.0, f"최대 F0 오류: {session.max_pitch}"
    assert len(session.events) == 1, f"격양 구간이 {len(session.events)}개로 분리됨"
    assert 2.5 <= session.agitated_seconds <= 4.5, f"격양 구간 길이 오류: {session.agitated_seconds}"
    assert session.rms_count > 0
    average = session.rms_sum / session.rms_count
    assert -50.0 < average < -25.0, f"평균 dB 오류: {average}"
    return (
        f"세션 메타데이터: 피크 {session.peak_rms:.0f}dB · 최대 {session.max_pitch:.0f}Hz · "
        f"격양 {len(session.events)}구간 {session.agitated_seconds:.1f}초"
    )


def scenario_noise_floor_tracking():
    gate = TwoStageGateMirror("medium")
    for _ in range(200):
        gate.step(-54.0)
    floor_loud = gate.noise_floor
    for _ in range(400):
        gate.step(-68.0)  # 더 조용한 방으로 이동
    assert floor_loud > -56.0, f"초기 배경 소음 프라이밍 오류: {floor_loud}"
    assert gate.noise_floor < -63.0, f"조용해진 배경으로 추종되지 않음: {gate.noise_floor:.1f}dB"
    return f"배경 소음 추종: -54dB -> {gate.noise_floor:.1f}dB"


def scenario_steady_loud_environment():
    """TV를 계속 틀어둔 환경 — 게이트가 열린 채 유지된다(정확도 우선 설계)."""
    gate = TwoStageGateMirror("medium")
    for _ in range(20):
        gate.step(-62.0)
    for _ in range(1200):  # 60초 연속 -42dB
        gate.step(-42.0)
    assert gate.state == "open", "연속 고음량 환경에서 게이트가 닫힘"
    return (
        f"연속 고음량(TV) 환경: 게이트 유지 · 2단계 {gate.deep_ratio:.0%} "
        "(배경 소음은 게이트가 닫힌 프레임에서만 추종 — 정확도 우선)"
    )



# ---------------------------------------------------------------------------
# 미러: EpisodeSummarizer (온디바이스 전사 -> 격양 타임라인 매핑 -> 쟁점 요약)
# ---------------------------------------------------------------------------

@dataclass
class EpisodeEvent:
    started_at_offset: float
    ended_at_offset: float
    peak_score: float


MIN_AGITATION_OVERLAP_S = 0.2
AGITATED_KEYWORD_WEIGHT = 2.0
MAXIMUM_KEYWORDS = 5
MAXIMUM_MARKERS = 20
MINIMUM_KEYWORD_LENGTH = 2

STOPWORDS = {
    "그", "저", "것", "수", "때", "좀", "더", "안", "못", "뭐", "왜", "응", "네", "예", "아", "어", "음",
    "이거", "그거", "저거", "그냥", "진짜", "정말", "너무", "많이", "다시", "이제", "아직", "또", "및", "등",
    "거", "건", "게", "듯", "분", "쪽", "중", "위해", "대해", "대한", "관해",
    "하고", "하는", "한다", "했다", "해서", "하면", "하지", "합니다", "입니다",
    "있어", "없어", "있다", "없다", "같아", "같은", "그리고", "그런데", "근데", "하지만", "그래서", "그러면", "그럼",
    "너", "나", "우리", "당신", "제가", "내가", "니가", "네가", "저는", "나는",
    "the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "at", "is", "are", "was", "were",
    "i", "you", "we", "it", "this", "that", "yeah", "ok", "okay", "um", "uh",
}

KOREAN_SUFFIXES = [
    "에서는", "에서도", "에게는", "으로는", "으로서", "이라는", "이라서", "이라고", "라는", "라고",
    "합니다", "입니다", "했는데", "하다가", "했어요", "하는데", "했어", "한다", "했다", "해서", "하면",
    "하고", "하지", "인데", "이며", "이고", "이나", "라도", "든지", "까지", "부터", "보다", "처럼",
    "마다", "조차", "밖에", "한테", "에게", "에서", "으로", "로서", "이랑", "와는", "과는",
    "은", "는", "이", "가", "을", "를", "에", "의", "도", "와", "과", "로", "만", "께", "랑", "야", "아", "요", "죠", "네",
]


def tokenize(text):
    return re.findall(r"[0-9a-z가-힣]+", text.lower())


def stem(token):
    for suffix in KOREAN_SUFFIXES:
        if len(token) > len(suffix) and token.endswith(suffix):
            return token[: -len(suffix)]
    return token


def overlap_seconds(segment, event):
    lower = max(segment["start"], event.started_at_offset)
    upper = min(segment["end"], event.ended_at_offset)
    return max(0.0, upper - lower)


def annotate(segments, events):
    result = []
    for segment in sorted(segments, key=lambda s: (s["start"], s["end"], s["text"])):
        overlap_total = 0.0
        peak = 0.0
        indexes = []
        for index, event in enumerate(events):
            overlap = overlap_seconds(segment, event)
            if overlap <= 0:
                continue
            overlap_total += overlap
            indexes.append(index)
            peak = max(peak, event.peak_score)
        is_agitated = overlap_total >= MIN_AGITATION_OVERLAP_S and bool(indexes)
        result.append(
            {
                "text": segment["text"],
                "start": segment["start"],
                "end": segment["end"],
                "overlap": overlap_total,
                "peak": peak if is_agitated else 0.0,
                "indexes": indexes,
                "is_agitated": is_agitated,
            }
        )
    return result


def select_key_claim(transcript, events):
    agitated = [s for s in transcript if s["is_agitated"]]
    if agitated:
        best = agitated[0]
        for candidate in agitated[1:]:
            if (candidate["peak"], candidate["overlap"], -candidate["start"]) > (
                best["peak"],
                best["overlap"],
                -best["start"],
            ):
                best = candidate
        event_index = max(best["indexes"], key=lambda i: (events[i].peak_score, -i))
        return {
            "text": best["text"],
            "start": best["start"],
            "end": best["end"],
            "peak": best["peak"],
            "overlap": best["overlap"],
            "event_index": event_index,
            "fallback": False,
        }
    if not transcript or not events:
        return None
    peak_index = max(range(len(events)), key=lambda i: (events[i].peak_score, -i))
    peak_event = events[peak_index]

    def gap(segment):
        if segment["end"] < peak_event.started_at_offset:
            return peak_event.started_at_offset - segment["end"]
        if segment["start"] > peak_event.ended_at_offset:
            return segment["start"] - peak_event.ended_at_offset
        return 0.0

    nearest = min(transcript, key=lambda s: (gap(s), s["start"]))
    return {
        "text": nearest["text"],
        "start": nearest["start"],
        "end": nearest["end"],
        "peak": peak_event.peak_score,
        "overlap": nearest["overlap"],
        "event_index": peak_index,
        "fallback": True,
    }


def extract_keywords(transcript):
    counts = {}
    weights = {}
    for segment in transcript:
        increment = AGITATED_KEYWORD_WEIGHT if segment["is_agitated"] else 1.0
        for token in tokenize(segment["text"]):
            base = stem(token)
            term = base if len(base) >= MINIMUM_KEYWORD_LENGTH else token
            if len(term) < MINIMUM_KEYWORD_LENGTH:
                continue
            if term in STOPWORDS or base in STOPWORDS:
                continue
            if not any(ch.isalpha() for ch in term):
                continue
            counts[term] = counts.get(term, 0) + 1
            weights[term] = weights.get(term, 0.0) + increment
    ranked = sorted(counts, key=lambda term: (-weights[term], -counts[term], term))
    return [(term, counts[term], weights[term]) for term in ranked[:MAXIMUM_KEYWORDS]]


def make_markers(transcript, events, key_claim):
    markers = []
    if key_claim:
        markers.append(("keyClaim", key_claim["start"], key_claim["peak"]))
    for index, event in enumerate(events):
        overlapping = [s for s in transcript if index in s["indexes"]]
        if overlapping:
            peak_segment = max(overlapping, key=lambda s: (s["peak"], s["overlap"], -s["start"]))
            offset = peak_segment["start"]
        else:
            offset = event.started_at_offset + (event.ended_at_offset - event.started_at_offset) * 0.5
        markers.append(("agitationPeak", offset, event.peak_score))
    markers.sort(key=lambda m: (m[1], -m[2], 0 if m[0] == "keyClaim" else 1))
    return markers[:MAXIMUM_MARKERS]


def scenario_episode_summary():
    """전사 타임라인 8구간 + 격양 3구간: 매핑·핵심 쟁점·키워드·마커가 Swift 테스트와 같은 값인지."""
    events = [
        EpisodeEvent(5.0, 8.1, 0.93),
        EpisodeEvent(22.5, 25.8, 0.88),
        EpisodeEvent(41.0, 44.0, 0.71),
    ]
    segments = [
        {"text": "오늘 저녁에 뭐 먹을지 이야기해 보자", "start": 0.0, "end": 3.4},
        {"text": "너는 또 약속 시간을 어겼잖아", "start": 4.2, "end": 7.0},
        {"text": "지난번에도 약속을 지키지 않았어", "start": 7.6, "end": 10.2},
        {"text": "그건 내가 회사 일이 있어서 그런 거야", "start": 12.0, "end": 16.0},
        {"text": "약속이라는 건 서로 지켜야 하는 거야", "start": 21.0, "end": 23.4},
        {"text": "알았어 다음엔 시간 지킬게", "start": 24.0, "end": 26.5},
        {"text": "그렇게 말하면 나는 항상 시간에 늦는 사람이 돼", "start": 40.0, "end": 43.2},
        {"text": "오늘은 그만 싸우고 밥 먹자", "start": 50.0, "end": 54.0},
    ]
    transcript = annotate(segments, events)
    assert len(transcript) == 8
    assert transcript[1]["is_agitated"] and transcript[1]["indexes"] == [0]
    assert abs(transcript[1]["overlap"] - 2.0) < 1e-9
    assert transcript[0]["is_agitated"] is False and transcript[0]["indexes"] == []

    claim = select_key_claim(transcript, events)
    assert claim["text"] == "너는 또 약속 시간을 어겼잖아", claim
    assert abs(claim["start"] - 4.2) < 1e-9 and claim["event_index"] == 0

    keywords = extract_keywords(transcript)
    assert [term for term, _, _ in keywords[:2]] == ["시간", "약속"], keywords
    assert keywords[0][1] == 3 and abs(keywords[0][2] - 6.0) < 1e-9

    speech_seconds = sum(s["end"] - s["start"] for s in transcript)
    agitated_speech = sum(s["end"] - s["start"] for s in transcript if s["is_agitated"])
    assert abs(speech_seconds - 24.9) < 1e-9, speech_seconds
    assert abs(agitated_speech - 13.5) < 1e-9, agitated_speech

    markers = make_markers(transcript, events, claim)
    assert [m[0] for m in markers] == ["keyClaim", "agitationPeak", "agitationPeak", "agitationPeak"], markers
    assert [round(m[1], 1) for m in markers] == [4.2, 4.2, 24.0, 40.0], markers
    return (
        f"에피소드 요약: 핵심 쟁점 '{claim['text']}' · 키워드 "
        f"{', '.join(t for t, _, _ in keywords[:2])} · 발화 {speech_seconds:.1f}초 · "
        f"격양 발화 {agitated_speech:.1f}초 · 마커 {len(markers)}개"
    )


def run_tests():
    results = []

    results.append(scenario_calm_conversation())
    results.append(scenario_single_burst())
    results.append(scenario_sustained_agitation())
    results.append(scenario_battery_night())
    results.append(scenario_battery_daytime())
    results.append(scenario_gated_frames_never_trigger())
    results.append(scenario_hysteresis())
    results.append(scenario_session_metadata())
    results.append(scenario_noise_floor_tracking())
    results.append(scenario_steady_loud_environment())
    results.append(scenario_episode_summary())

    print("=" * 78)
    print(f"VoiceGuard DSP 시나리오 검증 — {len(results)}개 시나리오 통과")
    print("=" * 78)
    for index, line in enumerate(results, start=1):
        print(f"  {index}. {line}")
    print("=" * 78)
    print(f"ALL DSP SCENARIO TESTS PASSED ({len(results)}/{len(results)})")


if __name__ == "__main__":
    run_tests()
