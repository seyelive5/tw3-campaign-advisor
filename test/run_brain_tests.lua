--[[===========================================================================
  TW3 어드바이저 — 오프라인 두뇌 테스트 (LuaJIT = Lua 5.1 세만틱)
  ---------------------------------------------------------------------------
  게임 없이 두뇌(analyze/diagnose/build_prose/build_briefing/josa/추세)를
  합성 상태(S 테이블)로 검증한다. 사용:
    luajit test\run_brain_tests.lua "C:\Users\veria\tw3-campaign-advisor"
  stdout = ASCII 요약(PASS/FAIL). 전체 한국어 리포트 = test\out_brain_report.txt
  ※ 주의: 게임 전용 API 경계(pooled resource 실재 여부 등)는 여기서 못 잡는다.
=============================================================================]]

local ROOT = arg and arg[1] or "."

-- ── 스텁 ──────────────────────────────────────────────────────────────
out = function() end                       -- 게임 로그 무음
core, find_uicomponent, UIComponent = nil, nil, nil  -- (로드시 미사용)
common = nil                               -- 로컬라이즈 없음 → 키 폴백 경로 검증

-- 실제 프루프 파일 보호: mod 상단 proof()가 io.open을 치므로 경로 차단
local real_open = io.open
io.open = function(path, mode)
	if type(path) == "string" and path:find("tw3_advisor", 1, true) then return nil end
	return real_open(path, mode)
end

-- cm 스텁 (테스트별로 필드 교체)
cm = {
	get_saved_value = function() return nil end,
	set_saved_value = function(self, k, v) cm._saved_k, cm._saved_v = k, v end,
	get_local_faction = function() return nil end,
	get_faction = function() return nil end,
	turn_number = function() return 1 end,
}

-- ── 모드 로드 ─────────────────────────────────────────────────────────
dofile(ROOT .. "/src/script/campaign/mod/za_faction_profiles.lua")
ADVISOR_TEST_EXPORTS = true
dofile(ROOT .. "/src/script/campaign/mod/campaign_advisor.lua")
assert(CA_TEST, "CA_TEST export 실패")
local T = CA_TEST

-- ── 어서션 엔진 ───────────────────────────────────────────────────────
local R = { pass = 0, fail = 0, lines = {} }
local function log(s) R.lines[#R.lines + 1] = s end
local function ok(cond, label, extra)
	if cond then R.pass = R.pass + 1; log("PASS  " .. label)
	else R.fail = R.fail + 1; log("FAIL  " .. label .. (extra and ("  ← " .. tostring(extra)) or "")) end
end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

-- ── S 빌더 ────────────────────────────────────────────────────────────
local function baseS(o)
	local S = {
		faction = "wh_main_emp_empire", subculture = "wh_main_sc_emp_empire", culture = "wh_main_emp_empire",
		leader_name = "Karl", leader_key = "wh_main_emp_karl_franz",
		turn = 20, treasury = 9000, income = 3000, net = 800, losing = false,
		regions = 5, provinces = 2, armies = 4, generals = 3, research_idle = false,
		war_count = 1, border_enemies = {}, war_set = {}, border_others = { "wh_main_brt_bretonnia" },
		immediate = 0, distant = 1, my_regions = 5,
		weak_target = nil, weak_target_r = 9999, strong_enemy = nil, strong_enemy_r = -1,
		war_names = {},
		threats = { sieges = {}, threatened = {}, targets = {}, my_field = {} },
		diplo = { peace = {}, ally = {} },
		province = { unrest = {} },
		snowball = nil, resource = nil, trend = nil, rival_growth = nil,
	}
	for k, v in pairs(o or {}) do S[k] = v end
	return S
end
local function run(S, prof)
	prof = prof or T.get_profile(S)
	S.proj = S.proj or T.project(S)   -- v37: 인게임 배선(run_advisor)과 동일
	local D, cand = T.analyze(S, prof)
	local dg = T.diagnose(S, D)
	local prose = T.build_prose(S, D, cand, prof)
	local brief = T.build_briefing(S, D, cand, prof)
	return D, cand, dg, prose, brief, prof
end

-- ══ 1. josa / has_batchim ═══════════════════════════════════════════
log("== 1. 한국어 조사 ==")
ok(T.has_batchim("제국") == true,  "받침: 제국=true")
ok(T.has_batchim("브레토니아") == false, "받침: 브레토니아=false")
ok(T.has_batchim("군사") == false, "받침: 군사=false")
ok(T.has_batchim("확장") == true,  "받침: 확장=true")
ok(T.has_batchim("기술") == true,  "받침: 기술=true")
ok(T.has_batchim("외교") == false, "받침: 외교=false")
ok(T.has_batchim("Kislev") == nil, "받침: 비한글=nil")
ok(T.josa("제국", "은", "는") == "은", "조사: 제국+은")
ok(T.josa("외교", "이", "가") == "가", "조사: 외교+가")

-- ══ 2. 국면 진단(diagnose) 우선순위 ═════════════════════════════════
log("== 2. 국면 진단 ==")
do  -- 제국 턴1 전쟁중 → '초반 정착'(v20 회귀 테스트: 소모전 오진 금지)
	local S = baseS{ turn = 1, immediate = 1, war_count = 2, distant = 1,
		border_enemies = { "wh_main_emp_empire_separatists" }, war_names = { "제국 분리주의자" } }
	local _, _, dg, prose = run(S)
	ok(dg and dg.label == "초반 정착", "턴1 교전 → 초반 정착", dg and dg.label)
	ok(has(prose, "제국은"), "산문: '제국은' 조사")
	ok(not has(prose, "제국는"), "산문: '제국는' 없음")
end
do  -- 적자+버퍼<4 → 재정 위기
	local S = baseS{ turn = 30, net = -800, losing = true, treasury = 2000, income = 1000 }
	local _, _, dg, prose = run(S)
	ok(dg and dg.label == "재정 위기", "적자 → 재정 위기", dg and dg.label)
	ok(has(prose, "적자"), "산문: 적자 언급")
end
do  -- 영토8/야전군2 + 2전선 → 과확장
	local S = baseS{ turn = 40, regions = 8, my_regions = 8, generals = 2, immediate = 2,
		border_enemies = { "a", "b" }, war_count = 2, war_names = { "A", "B" } }
	local _, _, dg = run(S)
	ok(dg and dg.label == "과확장", "얇은 군대+2전선 → 과확장", dg and dg.label)
end
do  -- 포위 → 궁지 + 산문 긴급 줄
	local S = baseS{ turn = 25, immediate = 1, border_enemies = { "e" }, war_names = { "적" },
		threats = { sieges = { "test_region_alpha" }, threatened = {}, targets = {}, my_field = {} } }
	local _, _, dg, prose = run(S)
	ok(dg and dg.label == "궁지", "포위 → 궁지", dg and dg.label)
	ok(has(prose, "긴급 — 포위된 정착지"), "산문: 포위 긴급 줄")
	ok(has(prose, "Alpha"), "산문: 지역명 폴백(Alpha)")
end
do  -- 평온+금고과다 → 성장 정체
	local S = baseS{ turn = 25, immediate = 0, war_count = 0, distant = 0, net = 2000, treasury = 40000, income = 2000 }
	local _, _, dg = run(S)
	ok(dg and dg.label == "성장 정체", "금고과다 → 성장 정체", dg and dg.label)
end
do  -- 턴30 교전1 → 소모전
	local S = baseS{ turn = 30, immediate = 1, border_enemies = { "e" }, war_names = { "적" } }
	local _, _, dg = run(S)
	ok(dg and dg.label == "소모전", "중반 교전 → 소모전", dg and dg.label)
end

-- ══ 3. 신규 모듈 산문 ═══════════════════════════════════════════════
log("== 3. 위협/확장/외교/내정/스노우볼 산문 ==")
do  -- 무방비 위협 + 확장 표적 + 외교
	local S = baseS{ immediate = 1, border_enemies = { "wh_dlc03_bst_beastmen" }, war_names = { "비스트맨" },
		threats = { sieges = {}, my_field = {},
			threatened = { { region = "region_of_nuln", faction = "wh_dlc03_bst_beastmen", defended = false } },
			targets = { { region = "tor_achare", owner = "wh_dlc03_bst_beastmen", my_border = "x", near = true } } },
		diplo = { peace = { "wh_dlc03_bst_beastmen" }, ally = { "wh_main_brt_bretonnia" } } }
	local _, cand, _, prose = run(S)
	ok(has(prose, "위협 — ") and has(prose, "근처 아군이 없습니다"), "산문: 무방비 위협")
	ok(has(prose, "확장 기회 — "), "산문: 확장 표적")
	-- v35: 화친+동맹 동시 → 한 문장 병합(조사 과는/와는 포함)
	ok(has(prose, "비스트맨과는 화친이") and has(prose, "브레토니아와는 군사동맹이 성사 가능합니다"), "산문: 화친+동맹 병합(v35)", prose:match("외교[^\n]*"))
	local found = false
	for _, c in ipairs(cand) do if c.key == "diplomacy" then found = true end end
	ok(found, "분석: 외교 후보 생성")
end
do  -- 반란+타락+연구+종족자원(주입)
	local S = baseS{ research_idle = true,
		province = { unrest = { { region = "reg_frauenburg", po = -60 } },
			corruption = { region = "reg_nuln", label = "너글", value = 77 } },
		resource = { label = "제국 권위", value = 22, note = "권위가 낮아 선제후 이탈 위험", urgent = true } }
	local _, _, _, prose = run(S)
	ok(has(prose, "반란 위험"), "산문: 반란 위험(po -60)")
	ok(has(prose, "타락 주의") and has(prose, "너글") and has(prose, "77"), "산문: 타락 경고")
	ok(has(prose, "연구가 지정되지 않았습니다"), "산문: 연구 넛지")
	ok(has(prose, "제국 권위 22"), "산문: 종족자원 줄")
end
do  -- 스노우볼: 주시(급성장) / 경계(압도)
	local S1 = baseS{ snowball = { key = "wh_main_grn_greenskins", regions = 9, dominant = false },
		rival_growth = { dt = 3, growth = 4 } }
	local _, _, _, p1 = run(S1)
	ok(has(p1, "주시 — ") and has(p1, "급성장"), "산문: 스노우볼 주시(급성장)")
	local S2 = baseS{ snowball = { key = "wh_main_grn_greenskins", regions = 20, dominant = true },
		rival_growth = { dt = 5, growth = 6 } }
	local _, _, _, p2 = run(S2)
	ok(has(p2, "경계 — ") and has(p2, "급성장"), "산문: 스노우볼 경계+급성장")
end

-- ══ 4. 추세/히스토리 순수 로직 ══════════════════════════════════════
log("== 4. 추세·히스토리 ==")
do
	local hist = {
		{ faction = "f", turn = 3, treasury = 100, regions = 2, armies = 1, income = 50 },
		{ faction = "f", turn = 5, treasury = 200, regions = 3, armies = 1, income = 70 },
		{ faction = "g", turn = 6, treasury = 999, regions = 9, armies = 9, income = 999 },
	}
	local S = baseS{ faction = "f", turn = 7, treasury = 350, regions = 4, income = 90 }
	local tr = T.compute_trend(S, hist)
	ok(tr and tr.dt == 2 and tr.treasury == 150 and tr.regions == 1 and tr.income == 20,
		"compute_trend: 최신 이전턴(5) 기준 델타", tr and (tr.dt .. "/" .. tr.treasury))
	local S2 = baseS{ turn = 6, snowball = { key = "R", regions = 10 } }
	local hist2 = {
		{ faction = "f", turn = 2, rival_key = "R", rival_regions = 6 },
		{ faction = "f", turn = 4, rival_key = "-", rival_regions = 0 },
	}
	local g = T.compute_rival_growth(S2, hist2)
	ok(g and g.dt == 4 and g.growth == 4, "compute_rival_growth: R 6→10 (+4/4턴)", g and (g.dt .. "/" .. g.growth))
	-- record_snapshot: 8필드 직렬화 + 12행 캡
	local big = {}
	for i = 1, 15 do big[#big + 1] = { faction = "f", turn = i, treasury = i, regions = i, armies = i, income = i } end
	cm._saved_k, cm._saved_v = nil, nil
	T.record_snapshot(baseS{ faction = "f", turn = 99 }, big)
	local rows = 0
	if type(cm._saved_v) == "string" then
		for line in cm._saved_v:gmatch("[^\n]+") do
			rows = rows + 1
			local fields = 0; for _ in (line .. "|"):gmatch("([^|]*)|") do fields = fields + 1 end
			if fields ~= 8 then ok(false, "record_snapshot: 8필드 직렬화", line) end
		end
	end
	ok(cm._saved_k == "advisor_history" and rows == 12, "record_snapshot: 키+12행 캡", tostring(rows))
end

-- ══ 5. gather_resource 파이프라인(스텁 prm) ═════════════════════════
log("== 5. 종족자원 파이프라인 ==")
do
	local function fake_res(v, null)
		return { is_null_interface = function() return null == true end, value = function() return v end }
	end
	local function with_prm(map)
		cm.get_local_faction = function()
			return { pooled_resource_manager = function()
				return { resource = function(self, key) return map[key] end }
			end }
		end
	end
	local prof = CA_FACTION_PROFILES["wh_main_sc_emp_empire"]
	with_prm({ ["emp_imperial_authority_new"] = fake_res(12) })
	local r = T.gather_resource(prof)
	ok(r and r.urgent == true and has(r.note, "권위가 낮아"), "권위12 → 긴급 low_note", r and r.note)
	with_prm({ ["emp_imperial_authority_new"] = fake_res(66) })
	r = T.gather_resource(prof)
	ok(r and r.urgent == false and r.value == 66, "권위66 → 일반 note")
	with_prm({ ["emp_imperial_authority_new"] = fake_res(0, true) })  -- null interface
	r = T.gather_resource(prof)
	ok(r == nil, "null interface → nil(줄 생략)")
	cm.get_local_faction = function() return nil end
end

-- ══ 6. 전 프로필·전 군주 무결성 스윕 ════════════════════════════════
log("== 6. 24프로필 + 전 군주 스윕 ==")
do
	local profs, lords_total = 0, 0
	for sub, prof in pairs(CA_FACTION_PROFILES) do
		profs = profs + 1
		local S = baseS{ subculture = sub, faction = sub .. "_test", leader_key = nil }
		local okrun, err = pcall(function()
			local D, cand = T.analyze(S, prof)
			local prose = T.build_prose(S, D, cand, prof)
			assert(type(prose) == "string" and #prose > 0, "빈 산문")
			assert(prose:find(prof.race, 1, true), "산문에 종족명 없음: " .. prof.race)
			T.build_briefing(S, D, cand, prof)
		end)
		ok(okrun, "프로필 무결성: " .. sub, err)
		for lk, lord in pairs(prof.lords or {}) do
			lords_total = lords_total + 1
			local S2 = baseS{ subculture = sub, leader_key = lk }
			local ok2, err2 = pcall(function()
				local D, cand = T.analyze(S2, prof)
				local prose = T.build_prose(S2, D, cand, prof)
				assert(prose:find(lord.name, 1, true), "군주 줄 없음: " .. lord.name)
			end)
			ok(ok2, "군주: " .. (lord.name or lk), err2)
		end
	end
	log(string.format(".. 프로필 %d개 · 군주 %d명 스윕", profs, lords_total))
end

-- ══ 7. nil 폭풍(수집 실패 시나리오) ═════════════════════════════════
log("== 7. nil 폭풍 ==")
do
	local S = {
		faction = "wh_x", war_names = {},
		threats = { sieges = {}, threatened = {}, targets = {}, my_field = {} },
		diplo = { peace = {}, ally = {} }, province = { unrest = {} },
	}
	local prof = T.get_profile(S)
	local okrun, err = pcall(function()
		local D, cand = T.analyze(S, prof)
		T.diagnose(S, D)
		local prose = T.build_prose(S, D, cand, prof)
		local brief = T.build_briefing(S, D, cand, prof)
		assert(#prose > 0 and #brief > 0)
	end)
	ok(okrun, "전 필드 nil이어도 무예외", err)
end

-- ══ 8. 전략 2.0 계획 엔진 ═══════════════════════════════════════════
log("== 8. 전략 2.0 계획 엔진 ==")
do
	-- 직렬화 왕복
	local p0 = { steps = {
		{ kind = "elim", key = "wh_x", base = 4, last = 3, created = 10 },
		{ kind = "prov", key = "reikland", base = 4, last = 2, created = 10 },
		{ kind = "posture", key = "tech", base = 0, last = 0, created = 11 },
	} }
	local p1 = T.plan_deserialize(T.plan_serialize(p0))
	ok(#p1.steps == 3 and p1.steps[1].kind == "elim" and p1.steps[1].key == "wh_x"
		and p1.steps[1].base == 4 and p1.steps[3].key == "tech", "직렬화 왕복")

	-- 생성: 제거(잔여 최소) + 속주(gap 최소) + 대비(무장 위기)
	local S = baseS{
		border_enemies = { "e_big", "e_small" }, war_set = { e_big = true, e_small = true },
		strat = {
			enemy = { e_big = { regions = 9 }, e_small = { regions = 2 } },
			provinces = { { key = "prov_a", owned = 1, total = 4 },
				{ key = "prov_b", owned = 3, total = 4, miss_region = "reg_gap", miss_owner = "e_small" } },
			armies = {}, endgame = { armed = { scenario = "endgame_vermintide", turn = 92 }, active = {} },
			my_rank = 7, victory = { vtype = "OCCUPY_LOOT_RAZE_OR_SACK_X_SETTLEMENTS", total = 60 },
		} }
	local plan = T.plan_generate(S, "소모전")
	-- v32 시너지: prov_b(미보유 소유주=e_small)는 ① 제거에 흡수 → ②는 차선 prov_a
	ok(#plan.steps == 3 and plan.steps[1].kind == "elim" and plan.steps[1].key == "e_small"
		and plan.steps[2].kind == "prov" and plan.steps[2].key == "prov_a"
		and plan.steps[3].kind == "prep", "생성: 표적/속주(시너지 제외)/대비 선택",
		plan.steps[1] and (tostring(plan.steps[1].key) .. "/" .. tostring(plan.steps[2] and plan.steps[2].key)))

	-- 갱신: 기준선 승계 + 추세(순항) + 산문
	local old = { steps = { { kind = "elim", key = "e_small", base = 4, last = 3, created = 5 } } }
	local np, ev = T.plan_revise(S, "소모전", old)
	ok(np.steps[1].kind == "elim" and np.steps[1].base == 4 and np.steps[1].last == 2
		and np.steps[1].prev == 3 and np.steps[1].created == 5,
		"갱신: 기준선(시작4)·prev(3)·created 승계",
		tostring(np.steps[1].base) .. "/" .. tostring(np.steps[1].prev))
	S.plan, S.plan_events = np, ev
	local blob = table.concat(T.plan_prose_lines(S), "\n")
	ok(has(blob, "【전략 계획】") and has(blob, "국력 7위") and has(blob, "60"), "산문: 헤더(국력·장기 승리)")
	ok(has(blob, "잔여 2정착지(시작 4)") and has(blob, "순항"), "산문: 제거 진행도")
	ok(has(blob, "1/4") and has(blob, "일석이조"), "산문: 차선 속주(1/4)+시너지 일석이조")
	ok(has(blob, "위기 대비") and has(blob, "92"), "산문: 엔드게임 대비")

	-- 완료 이벤트: 전선 종료(전쟁 목록에서 소멸)
	local S2 = baseS{ border_enemies = {}, war_set = {},
		strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} } } }
	local old2 = { steps = { { kind = "elim", key = "e_dead", base = 4, last = 1, created = 5 } } }
	local np2, ev2 = T.plan_revise(S2, "안정", old2)
	ok(#ev2 == 1 and has(ev2[1], "전선 종료"), "완료: 제거 대상 소멸 이벤트", ev2[1])
	ok(np2.steps[1] and np2.steps[1].kind == "posture", "완료 후 자세 단계로 재생성",
		np2.steps[1] and np2.steps[1].kind)

	-- 속주 완성 이벤트
	local S3 = baseS{ war_set = {},
		strat = { enemy = {}, provinces = { { key = "prov_b", owned = 4, total = 4 } }, armies = {}, endgame = { active = {} } } }
	local old3 = { steps = { { kind = "prov", key = "prov_b", base = 4, last = 3, created = 5 } } }
	local _, ev3 = T.plan_revise(S3, "안정", old3)
	ok(#ev3 == 1 and has(ev3[1], "속주 완성"), "완료: 속주 완성 이벤트", ev3[1])

	-- 군단 점검: 충원율 + 야포 경고
	local S4 = baseS{
		threats = { sieges = {}, threatened = {}, my_field = {},
			targets = { { region = "t", owner = "e", my_border = "b", near = true } } },
		strat = { enemy = {}, provinces = {}, endgame = { active = {} },
			armies = { { name = "카를", units = 19, art = 0, avg = 62 }, { name = "B", units = 10, art = 0, avg = 95 } } } }
	S4.plan = T.plan_generate(S4, "안정")
	local blob4 = table.concat(T.plan_prose_lines(S4), "\n")
	ok(has(blob4, "충원율 62%") and has(blob4, "야포 0문"), "산문: 군단 점검(충원·야포)")

	-- 진행 중 위기 경고
	local S5 = baseS{ war_set = {},
		strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = { "vermintide" } } } }
	S5.plan = T.plan_generate(S5, "안정")
	ok(has(table.concat(T.plan_prose_lines(S5), "\n"), "진행 중 위기"), "산문: 활성 위기 경고")

	-- 과확장 → 내실 자세 / strat nil 안전
	local S6 = baseS{ border_enemies = {}, strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} } } }
	local p6 = T.plan_generate(S6, "과확장")
	ok(p6.steps[#p6.steps] and p6.steps[#p6.steps].kind == "posture" and p6.steps[#p6.steps].key == "consolidate",
		"과확장 → consolidate 자세")
	local S7 = baseS{ strat = nil }
	local p7 = T.plan_generate(S7, nil)
	ok(p7.steps[1] and p7.steps[1].kind == "posture", "strat nil → posture 폴백")
	S7.plan = p7
	ok(#T.plan_prose_lines(S7) >= 1, "strat nil 산문 무예외")
	ok(T.endgame_disp("endgame_wild_hunt") == "wild hunt", "endgame_disp 정리")

	-- 일관성: 제거 표적은 화친 제안에서 분리(자기모순 해소, v30)
	local Sc = baseS{ diplo = { peace = { "pk_target" }, ally = {} },
		plan = { steps = { { kind = "elim", key = "pk_target", base = 3, last = 3, created = 1 } } } }
	local _, _, _, prose_c = run(Sc)
	ok(has(prose_c, "제거가 우선") and not has(prose_c, "화친이 성사 가능한 상대"),
		"일관성: 제거 표적 → 화친 제안 대체 문구")
	local Sc2 = baseS{ diplo = { peace = { "pk_target", "wh_main_brt_bretonnia" }, ally = {} },
		plan = { steps = { { kind = "elim", key = "pk_target", base = 3, last = 3, created = 1 } } } }
	local _, _, _, prose_c2 = run(Sc2)
	ok(has(prose_c2, "화친이 성사 가능한 상대: 브레토니아") and not has(prose_c2, "제거가 우선"),
		"일관성: 다른 상대는 정상 화친 제안")

	-- 승리 헤더: DESTROY_FACTION 대상 / 속주 장악형
	local Sv = baseS{ war_set = {},
		strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} }, my_rank = 5,
			victory = { vtype = "DESTROY_FACTION", targets = { "wh_main_grn_greenskins", "wh_main_vmp_vampire_counts", "x3" } } } }
	Sv.plan = T.plan_generate(Sv, "안정")
	local bv = table.concat(T.plan_prose_lines(Sv), "\n")
	ok(has(bv, "격멸") and has(bv, "그린스킨") and has(bv, "외 1"), "승리 헤더: 격멸 대상+외 N")
	local Sv2 = baseS{ war_set = {},
		strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} },
			victory = { vtype = "CONTROL", prov_need = 5 } } }
	Sv2.plan = T.plan_generate(Sv2, "안정")
	ok(has(table.concat(T.plan_prose_lines(Sv2), "\n"), "지정 속주 5곳 장악"), "승리 헤더: 속주 장악형")

	-- 슬라네쉬 자원 교체(신도) 파이프라인
	do
		local function fake_res(v) return { is_null_interface = function() return false end, value = function() return v end } end
		cm.get_local_faction = function()
			return { pooled_resource_manager = function()
				return { resource = function(self, key) if key == "wh3_main_sla_devotees" then return fake_res(30) end end }
			end }
		end
		local r = T.gather_resource(CA_FACTION_PROFILES["wh3_main_sc_sla_slaanesh"])
		ok(r and r.label == "신도" and r.value == 30, "슬라네쉬: devotees로 자원 해결", r and r.label)
		cm.get_local_faction = function() return nil end
	end

	-- 판단 고도화(v31): 생존 국면 → 최대 위협과 화친, 건재 → 제거
	local Sp = baseS{ turn = 25, immediate = 3, war_count = 3,
		border_enemies = { "big_e", "small_e" }, war_set = { big_e = true, small_e = true },
		war_names = { "빅", "스몰", "그외" },
		threats = { sieges = { "reg_sieged" }, threatened = {}, targets = {}, my_field = {} },
		diplo = { peace = { "big_e" }, ally = {} },
		strat = { enemy = { big_e = { regions = 9 }, small_e = { regions = 2 } },
			provinces = {}, armies = {}, endgame = { active = {} } } }
	local D_p = select(1, T.analyze(Sp, T.get_profile(Sp)))
	local dg_p = T.diagnose(Sp, D_p)
	ok(dg_p and dg_p.label == "궁지", "전제: 궁지 국면", dg_p and dg_p.label)
	local pp = T.plan_generate(Sp, dg_p.label)
	ok(pp.steps[1] and pp.steps[1].kind == "peace" and pp.steps[1].key == "big_e",
		"생존 국면 → 최대 위협과 화친 우선",
		pp.steps[1] and (pp.steps[1].kind .. ":" .. tostring(pp.steps[1].key)))
	ok(pp.steps[2] and pp.steps[2].kind == "elim" and pp.steps[2].key == "small_e",
		"화친 대상 제외한 최약체 제거 병행")
	Sp.plan = pp
	ok(has(table.concat(T.plan_prose_lines(Sp), "\n"), "강화 — ") , "산문: 화친 단계 줄")
	local _, _, _, prose_p = run(Sp)
	ok(not has(prose_p, "화친이 성사 가능한 상대") and not has(prose_p, "제거가 우선"),
		"일관성: 화친 단계가 외교 줄 흡수(중복·모순 없음)")
	local ph = T.plan_generate(Sp, "소모전")
	ok(ph.steps[1] and ph.steps[1].kind == "elim" and ph.steps[1].key == "small_e",
		"건재 국면 → 제거 우선(화친 단계 없음)", ph.steps[1] and ph.steps[1].kind)
	-- 화친 달성 이벤트 + 속주 추세
	local So = baseS{ war_set = {}, strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} } } }
	local oldp = { steps = { { kind = "peace", key = "gone_e", base = 9, last = 9, created = 3 } } }
	local _, evp = T.plan_revise(So, "안정", oldp)
	ok(#evp == 1 and has(evp[1], "전선 종료"), "화친 달성 이벤트", evp[1])
	local Sr = baseS{ war_set = {},
		strat = { enemy = {}, provinces = { { key = "prov_t", owned = 3, total = 4 } }, armies = {}, endgame = { active = {} } } }
	local oldr = { steps = { { kind = "prov", key = "prov_t", base = 4, last = 2, created = 3 } } }
	Sr.plan = T.plan_revise(Sr, "안정", oldr)
	ok(has(table.concat(T.plan_prose_lines(Sr), "\n"), "3/4 — 순항"), "속주 추세 순항(2→3)")

	-- v32: 전력 대조(승산)·시너지·정보 예산·중복 억제
	do
		local Sw = baseS{ border_enemies = { "foe" }, war_set = { foe = true },
			strat = { enemy = { foe = { regions = 3, strength = 4000 } }, my_strength = 9000,
				provinces = {}, armies = {}, endgame = { active = {} } } }
		Sw.plan = T.plan_generate(Sw, "소모전")
		ok(has(table.concat(T.plan_prose_lines(Sw), "\n"), "야전 전력 우위"), "전력 대조: 우위 표기")

		local Sl = baseS{ border_enemies = { "foe" }, war_set = { foe = true },
			diplo = { peace = { "foe" }, ally = {} },
			strat = { enemy = { foe = { regions = 3, strength = 9000 } }, my_strength = 3000,
				provinces = {}, armies = {}, endgame = { active = {} } } }
		local pl = T.plan_generate(Sl, "소모전")
		ok(pl.steps[1] and pl.steps[1].kind == "peace" and pl.steps[1].key == "foe",
			"승산 판단: 열세+화친가능 → 강화 전환(건재 국면에서도)", pl.steps[1] and pl.steps[1].kind)
		Sl.diplo = { peace = {}, ally = {} }
		local pl2 = T.plan_generate(Sl, "소모전")
		Sl.plan = pl2
		ok(pl2.steps[1] and pl2.steps[1].kind == "elim", "열세+화친불가 → 제거 유지")
		ok(has(table.concat(T.plan_prose_lines(Sl), "\n"), "열세 — 요격·증원"), "열세 경고 표기")

		local Ss = baseS{ border_enemies = { "foe" }, war_set = { foe = true },
			strat = { enemy = { foe = { regions = 2, strength = 1000 } }, my_strength = 5000,
				provinces = { { key = "provX", owned = 2, total = 3, miss_region = "rX", miss_owner = "foe" } },
				armies = {}, endgame = { active = {} } } }
		local ps = T.plan_generate(Ss, "소모전")
		local has_prov = false
		for _, st in ipairs(ps.steps) do if st.kind == "prov" then has_prov = true end end
		ok(not has_prov, "시너지: 속주 단계가 제거에 흡수")
		Ss.plan = ps
		ok(has(table.concat(T.plan_prose_lines(Ss), "\n"), "일석이조"), "시너지: 일석이조 문구")

		-- 정보 예산: 과부하 → 플레이버(팁·군주) 탈락 + 총량 상한
		local So2 = baseS{ turn = 30, immediate = 2, war_count = 4, distant = 2,
			border_enemies = { "e1", "e2" }, war_set = { e1 = true, e2 = true }, war_names = { "적1", "적2" },
			leader_key = "wh_main_emp_karl_franz", research_idle = true,
			trend = { dt = 3, treasury = 100, regions = 1, income = 50 },
			snowball = { key = "wh_main_grn_greenskins", regions = 30, dominant = true },
			rival_growth = { dt = 3, growth = 5 },
			resource = { label = "제국 권위", value = 12, note = "낮음", urgent = true },
			threats = { sieges = { "sg" }, my_field = {},
				threatened = { { region = "r1", faction = "e9", defended = false } },
				targets = { { region = "t1", owner = "e9", my_border = "b", near = true } } },
			diplo = { peace = { "e9" }, ally = { "a1" } },
			province = { unrest = { { region = "ru", po = -60 } }, corruption = { region = "rc", label = "너글", value = 80 } },
			strat = { enemy = { e1 = { regions = 4 }, e2 = { regions = 6 } }, my_strength = 5000,
				provinces = { { key = "pv", owned = 1, total = 3, miss_region = "mr", miss_owner = "zz" } },
				armies = { { name = "A", units = 10, art = 0, avg = 50 } },
				endgame = { armed = { scenario = "endgame_waaagh", turn = 60 }, active = { "vermintide" } } } }
		So2.plan = T.plan_revise(So2, "궁지", nil)
		local _, _, _, prose_o = run(So2)
		local nl = 0; for _ in prose_o:gmatch("[^\n]+") do nl = nl + 1 end
		ok(nl <= 16, "정보 예산: 과부하 총량 제한", tostring(nl))
		ok(not has(prose_o, "답게"), "정보 예산: 팁 탈락")
		ok(not has(prose_o, "카를 프란츠:"), "정보 예산: 군주 탈락")

		-- 중복 억제: 확장 표적 소유주가 계획 대상이면 확장줄 대신 계획 '다음 수'
		local Sv3 = baseS{ border_enemies = { "own" }, war_set = { own = true },
			threats = { sieges = {}, threatened = {}, my_field = {},
				targets = { { region = "tg", owner = "own", my_border = "b", near = true } } },
			strat = { enemy = { own = { regions = 2 } }, provinces = {}, armies = {}, endgame = { active = {} } } }
		Sv3.plan = T.plan_generate(Sv3, "소모전")
		local _, _, _, prose_v = run(Sv3)
		ok(not has(prose_v, "확장 기회 — "), "중복 억제: 커버된 확장줄 제거")
		ok(has(prose_v, "다음 수: "), "계획이 다음 수로 흡수")
	end

	-- v33: 기후 게이트·이동력 넛지·원거리 비중·자원 max 표시
	do
		-- 기후: 적합 우선 선택 / 부적합뿐이면 약탈 권고
		local Sc1 = baseS{
			threats = { sieges = {}, threatened = {}, my_field = {},
				targets = { { region = "reg_swamp", owner = "eX", my_border = "b", near = true, suit = "suitability_verypoor" },
					{ region = "reg_meadow", owner = "eX", my_border = "b", near = true, suit = "suitability_good" } } } }
		local _, _, _, pc1 = run(Sc1)
		ok(has(pc1, "확장 기회") and has(pc1, "Meadow"), "기후: 적합지 우선", pc1:match("확장[^\n]*"))
		ok(not has(pc1, "확장 주의"), "기후: 적합지 있으면 경고 없음")
		local Sc2 = baseS{
			threats = { sieges = {}, threatened = {}, my_field = {},
				targets = { { region = "bad_land", owner = "eX", my_border = "b", near = true, suit = "suitability_verypoor" } } } }
		local _, _, _, pc2 = run(Sc2)
		ok(has(pc2, "확장 주의") and has(pc2, "약탈"), "기후: 부적합뿐 → 약탈 권고")
		-- 다음 수 기후 선호(계획)
		local Sc3 = baseS{ border_enemies = { "foe" }, war_set = { foe = true },
			threats = { sieges = {}, threatened = {}, my_field = {},
				targets = { { region = "reg_swamp", owner = "foe", my_border = "b", near = true, suit = "suitability_verypoor" },
					{ region = "reg_meadow", owner = "foe", my_border = "b", near = true, suit = "suitability_good" } } },
			strat = { enemy = { foe = { regions = 3 } }, provinces = {}, armies = {}, endgame = { active = {} } } }
		Sc3.plan = T.plan_generate(Sc3, "소모전")
		local bc3 = table.concat(T.plan_prose_lines(Sc3), "\n")
		ok(has(bc3, "다음 수: Meadow 공략") and not has(bc3, "기후 부적합"), "계획 다음 수: 적합지 선호", bc3:match("다음 수[^\n]*"))
		Sc3.threats.targets = { { region = "reg_swamp", owner = "foe", my_border = "b", near = true, suit = "suitability_verypoor" } }
		local bc4 = table.concat(T.plan_prose_lines(Sc3), "\n")
		ok(has(bc4, "기후 부적합 — 약탈 권장"), "계획 다음 수: 부적합 주석")
		-- 이동력 넛지: 혼합 AP에서만
		local Sm = baseS{ strat = { enemy = {}, provinces = {}, endgame = { active = {} },
			armies = { { units = 19, art = 1, ranged = 5, combat = 18, ap = 10 },
				{ units = 15, art = 0, ranged = 4, combat = 14, ap = 100, in_open = true } } } }
		local _, _, _, pm = run(Sm)
		ok(has(pm, "이동력 — ") and has(pm, "1개"), "이동력: 혼합 AP → 미이동 1 넛지")
		Sm.strat.armies[1].ap = 100
		local _, _, _, pm2 = run(Sm)
		ok(not has(pm2, "이동력 — "), "이동력: 턴 초(전원 만땅) → 무음")
		-- 원거리 비중: 일반 종족 경고 / 근접 종족 제외
		local Sr1 = baseS{ threats = { sieges = {}, threatened = {}, my_field = {}, targets = {} },
			strat = { enemy = {}, provinces = {}, endgame = { active = {} },
				armies = { { name = "주력", units = 16, art = 0, ranged = 1, combat = 15, avg = 95 } } } }
		Sr1.plan = T.plan_generate(Sr1, "안정")
		ok(has(table.concat(T.plan_prose_lines(Sr1), "\n"), "원거리 7%"), "원거리 비중 경고(1/15=7%)")
		Sr1.melee_race = true
		ok(not has(table.concat(T.plan_prose_lines(Sr1), "\n"), "원거리"), "근접 종족 → 원거리 경고 제외")
		-- 자원 max 비율 표시
		local Sx = baseS{ resource = { label = "제국 권위", value = 12, max = 100, note = "낮음", urgent = true } }
		local _, _, _, px = run(Sx)
		ok(has(px, "제국 권위 12/100"), "자원 값/max 표시")
	end
end

-- ══ 9. v35 — 조사 강화·절 병합(aggregation)·신뢰성 3-상태 ═══════════
log("== 9. v35 조사·절병합·신뢰성 ==")
do
	-- 숫자 받침(tossi 규칙 이식)
	ok(T.has_batchim("146") == true,  "숫자 받침: 146(육)=true")
	ok(T.has_batchim("2") == false,   "숫자 받침: 2(이)=false")
	ok(T.has_batchim("10") == true,   "숫자 받침: 10(십)=true")
	ok(T.has_batchim("5") == false,   "숫자 받침: 5(오)=false")
	-- (으)로: ㄹ받침 예외 + 숫자
	ok(T.josa_ro("서울") == "로",   "(으)로: 서울→로(ㄹ예외)")
	ok(T.josa_ro("짚") == "으로",   "(으)로: 짚→으로")
	ok(T.josa_ro("외교") == "로",   "(으)로: 외교→로(모음)")
	ok(T.josa_ro("823") == "으로",  "(으)로: 823(삼)→으로")
	ok(T.josa_ro("821") == "로",    "(으)로: 821(일=ㄹ)→로")
	ok(T.josa_ro("530") == "으로",  "(으)로: 530(영/십)→으로")
	-- 절 병합기: 같은 극성 병렬(이고→이며), 극성 전환 1회만 '이나'
	local j1 = T.join_clauses({ T.clause("재정은 흑자", "n", 1), T.clause("수입도 오르는 추세", "n", 1), T.clause("국경은 평온", "h", 1) })
	ok(j1 == "재정은 흑자이고 수입도 오르는 추세이며 국경은 평온합니다", "병합: 전부 긍정(이고→이며 교대)", j1)
	local j2 = T.join_clauses({ T.clause("재정은 흑자", "n", 1), T.clause("국경에서 적의 압박을 받고 있", "v", -1) })
	ok(j2 == "재정은 흑자이나, 국경에서 적의 압박을 받고 있습니다", "병합: 극성 전환 1회(이나)", j2)
	local j3 = T.join_clauses({ T.clause("재정은 적자라 주의가 필요", "h", -1) })
	ok(j3 == "재정은 적자라 주의가 필요합니다", "병합: 단일 절", j3)
	local j4 = T.join_clauses({ T.clause("국경은 평온", "h", 1), T.clause("재정은 적자라 주의가 필요", "h", -1), T.clause("수입은 꺾이는 추세", "n", -1) })
	ok(j4 == "국경은 평온하나, 재정은 적자라 주의가 필요하고 수입은 꺾이는 추세입니다", "병합: 긍정1+부정2", j4)
end
do  -- 정세 문장 병합(경제+수입추세+위협 한 문장) + (으)로 실전
	local S = baseS{ net = 823, trend = { dt = 1, treasury = 458, regions = 0, income = 2 },
		immediate = 1, border_enemies = { "e" }, war_names = { "크레이스" } }
	local _, _, _, prose = run(S)
	ok(has(prose, "재정은 순 +823으로 흑자이고 수입도 오르는 추세이나, 국경에서 크레이스의 압박을 받고 있습니다"),
		"정세: 3절 병합 문장", prose:match("[^\n]*순 %+823[^\n]*"))
	ok(not has(prose, "최근 1턴 사이"), "정세: 수입 추세 별도 줄 제거(흡수)")
	local S2 = baseS{ net = 500, trend = { dt = 2, treasury = 100, regions = 1, income = -30 } }
	local _, _, _, p2 = run(S2)
	ok(has(p2, "수입은 꺾이는 추세"), "정세: 역방향 추세 → '은' 선택", p2:match("[^\n]*추세[^\n]*"))
	ok(has(p2, "최근 2턴 사이 영토가 늘었습니다"), "추세 줄: 영토만 잔류")
end
do  -- 내정 병합: 치안(N)+타락 → 한 문장 / 반란(U)이면 분리 유지
	local S = baseS{ province = { unrest = { { region = "reg_a", po = -20 } },
		corruption = { region = "reg_b", label = "너글", value = 66 } } }
	local _, _, _, prose = run(S)
	ok(has(prose, "내정 — ") and has(prose, "치안이 -20으로 낮고") and has(prose, "너글 타락이 66%"), "내정: 치안+타락 병합", prose:match("내정[^\n]*"))
	ok(not has(prose, "타락 주의 — "), "내정: 병합 시 타락 단독줄 제거")
	local Su = baseS{ province = { unrest = { { region = "reg_a", po = -60 } },
		corruption = { region = "reg_b", label = "너글", value = 66 } } }
	local _, _, _, pu = run(Su)
	ok(has(pu, "반란 위험") and has(pu, "타락 주의 — "), "내정: 반란(U)이면 타락 단독줄 유지")
	local Ss = baseS{ province = { unrest = { { region = "reg_a", po = -20 } },
		corruption = { region = "reg_a", label = "너글", value = 66 } } }
	local _, _, _, ps = run(Ss)
	ok(has(ps, "너글 타락도 66%에 달합니다"), "내정: 같은 지역 → '타락도' 병합", ps:match("내정[^\n]*"))
end
do  -- 신뢰성 3-상태(문서1 0순위): 실패=경고, 정상=침묵 — '조용함'의 의미를 명시
	local Sf = baseS{ health = { "위협", "외교" } }
	local _, _, _, pf, bf = run(Sf)
	ok(has(pf, "⚠ 데이터 — ") and has(pf, "위협·외교") and has(pf, "판단을 보류"), "신뢰성: 수집 실패 U 경고", pf:match("⚠[^\n]*"))
	ok(has(bf, "수집상태: 실패=위협,외교"), "신뢰성: 파일 브리핑 실패 표기")
	local So = baseS{ health = {} }
	local _, _, _, po2, bo = run(So)
	ok(not has(po2, "⚠ 데이터"), "신뢰성: 정상이면 경고 없음")
	ok(has(bo, "수집상태: 전 섹션 정상"), "신뢰성: 파일 브리핑 정상 표기")
	-- 외교 단독 경로 회귀(병합 아닌 기존 문구 유지)
	local Sp = baseS{ diplo = { peace = { "wh_main_brt_bretonnia" }, ally = {} } }
	local _, _, _, pp = run(Sp)
	ok(has(pp, "화친이 성사 가능한 상대: 브레토니아"), "외교: 화친 단독 문구 유지")
	local Sa = baseS{ diplo = { peace = {}, ally = { "wh_main_brt_bretonnia" } } }
	local _, _, _, pa = run(Sa)
	ok(has(pa, "군사동맹이 가능한 상대: 브레토니아"), "외교: 동맹 단독 문구 유지")
	-- 자원 note 대시 치환: 종결어미 뒤=마침표, 그 외=쉼표
	local Sn = baseS{ resource = { label = "신도", value = 146, note = "원천입니다 — 신도를 늘리세요" } }
	local _, _, _, pn = run(Sn)
	ok(has(pn, "원천입니다. 신도를 늘리세요"), "자원 note: '다 — ' → 마침표", pn:match("신도 146[^\n]*"))
	-- 트레이드오프(계획상 제거 우선)+동맹 → 병합 문장
	local St = baseS{ border_enemies = { "wh_dlc03_bst_beastmen" }, war_set = { wh_dlc03_bst_beastmen = true },
		diplo = { peace = { "wh_dlc03_bst_beastmen" }, ally = { "wh_main_brt_bretonnia" } },
		strat = { enemy = { wh_dlc03_bst_beastmen = { regions = 3 } }, provinces = {}, armies = {}, endgame = { active = {} } } }
	St.plan = T.plan_generate(St, "소모전")
	local _, _, _, pt = run(St)
	ok(has(pt, "화친도 성사 가능하나 계획상 제거가 우선입니다. 한편 브레토니아와는 군사동맹이"), "외교: 트레이드오프+동맹 병합", pt:match("외교[^\n]*"))
end

-- ══ 10. v36 — CAI 정찰(스탠스·군비) 조언 통합 ═══════════════════════
log("== 10. v36 CAI 정찰 ==")
do
	-- 적 군비 고갈(<300) → 계획 ①에 속전 신호 / 충분하면 무언
	local S = baseS{ border_enemies = { "foe" }, war_set = { foe = true },
		strat = { enemy = { foe = { regions = 3, strength = 4000, war_chest = 120 } }, my_strength = 9000,
			provinces = {}, armies = {}, endgame = { active = {} } } }
	S.plan = T.plan_generate(S, "소모전")
	local pl = table.concat(T.plan_prose_lines(S), "\n")
	ok(has(pl, "적 군비 고갈 — 몰아칠 때"), "CAI: 군비 고갈 → 속전 신호", pl:match("①[^\n]*"))
	S.strat.enemy.foe.war_chest = 5000
	local pl2 = table.concat(T.plan_prose_lines(S), "\n")
	ok(not has(pl2, "군비 고갈"), "CAI: 군비 충분 → 무언")
	-- 비전시 적대 이웃 경보(음수 스탠스) + 조사
	local Sh = baseS{ strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} },
		hostile = { { key = "wh_main_grn_greenskins", stance = -1 } } } }
	local _, _, _, ph, bh = run(Sh)
	ok(has(ph, "경계 — 이웃 그린스킨이 전쟁 전인데도 우리를 적대시"), "CAI: 적대 이웃 경보+조사(이)", ph:match("경계[^\n]*"))
	ok(has(bh, "적대이웃 그린스킨(-1)"), "CAI: 파일 브리핑 정찰 줄")
	local Sq = baseS{ strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} }, hostile = {} } }
	local _, _, _, pq = run(Sq)
	ok(not has(pq, "적대시"), "CAI: 적대 없음 → 무언")
end

-- ══ 11. v37 — 전방 투영(얕은 외삽): 활주로·격멸 ETA·라이벌 교차 ═════
log("== 11. v37 전방 투영 ==")
do
	-- project 순수 로직: 실측 추세 우선 / 폴백=순수입
	local P1 = T.project({ treasury = 6000, net = -1500, turn = 20 })
	ok(P1.runway == 4 and P1.t3 == 1500, "투영: 순수입 폴백(활주로 4턴, 3턴 뒤 1500)", P1.runway .. "/" .. P1.t3)
	local P2 = T.project({ treasury = 6000, net = 100, turn = 20, trend = { dt = 2, treasury = -4000, regions = 0, income = 0 } })
	ok(P2.rate == -2000 and P2.runway == 3, "투영: 실측 추세 우선(-2000/턴 → 활주로 3)", tostring(P2.rate))
	ok(T.project({ treasury = 9000, net = 800, turn = 20 }).runway == nil, "투영: 흑자면 활주로 없음")
	-- 라이벌 2배 교차: 라이벌 +2/턴, 나 +0/턴, 현재 라이벌 10 vs 나 8 → (16-10)/2 = 3턴
	local P3 = T.project({ treasury = 9000, net = 800, turn = 20, regions = 8,
		snowball = { key = "r", regions = 10 }, rival_growth = { dt = 2, growth = 4 },
		trend = { dt = 2, treasury = 1600, regions = 0, income = 0 } })
	ok(P3.rival_cross == 3, "투영: 라이벌 2배 교차 3턴", tostring(P3.rival_cross))
	local P4 = T.project({ treasury = 9000, net = 800, turn = 20, regions = 8,
		snowball = { key = "r", regions = 10 }, rival_growth = { dt = 2, growth = 0 },
		trend = { dt = 2, treasury = 1600, regions = 2, income = 0 } })
	ok(P4.rival_cross == nil, "투영: 내가 더 빠르면 교차 없음")
end
do  -- 산문: 재정위기 국면에 활주로 수치 부착
	local S = baseS{ turn = 30, net = -800, losing = true, treasury = 2000, income = 1000 }
	local _, _, _, prose = run(S)
	ok(has(prose, "【국면 · 재정 위기】") and has(prose, "이 추세면 ~2턴 내 고갈됩니다"), "투영: 국면에 활주로 부착", prose:match("국면[^\n]*"))
	ok(not has(prose, "재정 — 이 추세면"), "투영: 국면과 U줄 중복 없음")
end
do  -- 산문: 국면이 재정위기가 아닌데 활주로 짧음 → U 경고 (버퍼 넉넉·순손실 큼)
	local S = baseS{ turn = 30, net = -1500, losing = true, treasury = 4000, income = 800,
		war_count = 0, distant = 0 }
	local _, _, _, prose = run(S)
	ok(has(prose, "재정 — 이 추세면 약 2턴 뒤 국고가 바닥납니다"), "투영: 활주로 U 경고", prose:match("재정 — [^\n]*"))
end
do  -- 계획 ① 격멸 ETA: 시작4→잔여2, 2턴 경과 → 속도 1/턴 → ~2턴 내 정리
	local S = baseS{ turn = 12, border_enemies = { "foe" }, war_set = { foe = true },
		strat = { enemy = { foe = { regions = 2 } }, provinces = {}, armies = {}, endgame = { active = {} } } }
	S.plan = { steps = { { kind = "elim", key = "foe", base = 4, last = 2, created = 10 } } }
	local pl = table.concat(T.plan_prose_lines(S), "\n")
	ok(has(pl, "이 속도면 ~2턴 내 정리"), "투영: 격멸 ETA", pl:match("①[^\n]*"))
	S.plan.steps[1].created = 12   -- 방금 생성 → ETA 없음
	ok(not has(table.concat(T.plan_prose_lines(S), "\n"), "이 속도면"), "투영: 생성 직후엔 ETA 무음")
end
do  -- 주시 줄에 교차 시점 부착
	local S = baseS{ regions = 8, my_regions = 8,
		snowball = { key = "wh_main_grn_greenskins", regions = 10, dominant = false },
		rival_growth = { dt = 2, growth = 4 },
		trend = { dt = 2, treasury = 1600, regions = 0, income = 0 } }
	local _, _, _, prose = run(S)
	ok(has(prose, "주시 — ") and has(prose, "~3턴 뒤 우리의 2배 규모"), "투영: 주시 줄 교차 부착", prose:match("주시[^\n]*"))
end

-- ══ 12. v38 — IAUS-lite(근거 기여 순) + 국면 보간(tapered) ══════════
log("== 12. v38 근거 랭킹·국면 보간 ==")
do
	-- 근거 기여 순 정렬: 얇음(밀도0.25→+15) > 국경적1(+12) > 원거리2(+6)
	local S = baseS{ immediate = 1, distant = 2, war_count = 3, generals = 1, regions = 4, my_regions = 4,
		border_enemies = { "e" }, war_names = { "적" }, net = 0 }
	local _, cand = run(S)
	local mil
	for _, c in ipairs(cand) do if c.key == "military" then mil = c end end
	ok(mil and mil.reasons[1]:find("얇음") ~= nil and mil.reasons[2]:find("즉각 위협") ~= nil,
		"IAUS: 근거 기여 순 정렬(얇음>국경적>원거리)", mil and table.concat(mil.reasons, " | "))
	-- 응답곡선: 버퍼 3턴 → 경제 보너스 6(15×2/5) < 평온 12 → 근거 1위는 평온
	local S2 = baseS{}   -- treasury 9000/income 3000 = 버퍼 3, immediate 0
	local _, c2 = run(S2)
	local eco
	for _, c in ipairs(c2) do if c.key == "economy" then eco = c end end
	ok(eco and eco.reasons[1] == "국경 평온 — 성장 적기", "IAUS: 응답곡선(얕은 버퍼<평온 기여)", eco and table.concat(eco.reasons, " | "))
end
do
	-- 국면 보간: 포위+과확장 동시 → 궁지 주 국면 + 과확장 조짐 병기
	local S = baseS{ turn = 40, regions = 8, my_regions = 8, generals = 2, immediate = 2, war_count = 2,
		border_enemies = { "a", "b" }, war_names = { "A", "B" },
		threats = { sieges = { "sg" }, threatened = {}, targets = {}, my_field = {} } }
	local _, _, dg, prose = run(S)
	ok(dg and dg.label == "궁지" and dg.second == "과확장", "보간: 궁지+과확장 복합", (dg and dg.label or "?") .. "/" .. tostring(dg and dg.second))
	ok(has(prose, "과확장 조짐도 겹쳐 있습니다"), "보간: 복합 표기(산문)", prose:match("국면[^\n]*"))
	-- 약한 차점(0.45 미만)은 병기하지 않음
	local S2 = baseS{ turn = 30, net = -800, losing = true, treasury = 2000, income = 1000 }
	local _, _, dg2, p2 = run(S2)
	ok(dg2 and dg2.label == "재정 위기" and dg2.second == nil, "보간: 약한 차점 무병기", tostring(dg2 and dg2.second))
	ok(not has(p2, "조짐도"), "보간: 산문에도 무병기")
end

-- ══ 13. v39 — 아콘(WoC) 검증 후속: 영토0 거점·보강/기회 구분 ═══════
log("== 13. v39 영토0·보강/기회 ==")
do
	-- 영토 0 + 점령 가능 → 계획 ① 거점 확보(아콘 시작 상황)
	local S = baseS{ regions = 0, my_regions = 0, provinces = 0, generals = 1 }
	local pl = T.plan_generate(S, "초반 정착")
	ok(pl.steps[1] and pl.steps[1].kind == "posture" and pl.steps[1].key == "settle", "영토0: settle 계획", pl.steps[1] and tostring(pl.steps[1].key))
	S.plan = pl
	ok(has(table.concat(T.plan_prose_lines(S), "\n"), "거점 확보 — 아직 정착지가 없습니다"), "영토0: 거점 확보 문구")
	-- 호드(점령 불가)는 settle 제외
	local Sh = baseS{ regions = 0, my_regions = 0, can_capture = false }
	local ph = T.plan_generate(Sh, "초반 정착")
	ok(not (ph.steps[1] and ph.steps[1].key == "settle"), "호드: settle 제외", ph.steps[1] and tostring(ph.steps[1].key))
	-- 종합 줄: 영토 0이면 '군대 얇음' 미표기
	local _, _, _, _, brief = run(S)
	ok(not has(brief, "군대 얇음"), "영토0: '군대 얇음' 오진 제거")
end
do
	-- 보강/기회 구분(v38 랭킹 부작용 수정): 문제형 근거 우선, 기회뿐이면 라벨 전환
	local S = baseS{}   -- 버퍼 3.0 → 문제형(버퍼) 존재하나 기여 1위는 평온(12>6)
	local _, _, _, prose = run(S)
	ok(has(prose, "보강 — 경제: 재정 버퍼 3.0턴"), "보강: 문제형 근거 우선", prose:match("보강[^\n]*") or prose:match("기회[^\n]*"))
	local S2 = baseS{ treasury = 40000, income = 3000, net = 2000 }   -- 버퍼 13.3 → 문제형 없음
	local _, _, _, p2 = run(S2)
	ok(has(p2, "기회 — 경제: 국경 평온, 성장 적기"), "기회: 문제형 없으면 라벨 전환", p2:match("기회[^\n]*") or p2:match("보강[^\n]*"))
end

-- ══ 14. v40 — 코드리뷰 후속: 폴백 자세·활주로·센티넬·수집실패·호드 ═══
log("== 14. v40 코드리뷰 수정 ==")
do
	-- ① 계획 폴백이 국면을 무시하던 결함: 파산 직전에 "다음 전쟁 설계"가 나오던 케이스
	local Sc = baseS{ treasury = 800, income = 3000, net = -700, losing = true,
		weak_target = "wh_main_dwf_dwarfs", weak_target_r = 2,
		strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} } } }
	local pc = T.plan_generate(Sc, "재정 위기")
	ok(pc.steps[1] and pc.steps[1].key == "retrench", "폴백: 재정위기 → 긴축(확장 아님)", pc.steps[1] and tostring(pc.steps[1].key))
	Sc.plan = pc
	local pcl = table.concat(T.plan_prose_lines(Sc), "\n")
	ok(has(pcl, "긴축 — 적자를 멈추는 게 먼저입니다") and not has(pcl, "다음 전쟁을 설계"), "폴백: 긴축 문구", pcl:match("①[^\n]*"))
	-- 궁지(포위) + 적 정보 조회 실패 → 사수
	local Sh = baseS{ immediate = 1, border_enemies = { "e1" }, war_names = { "E" }, war_set = { e1 = true },
		threats = { sieges = { "cap" }, threatened = {}, targets = {}, my_field = {} },
		strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} } } }
	local ph = T.plan_generate(Sh, "궁지")
	ok(ph.steps[1] and ph.steps[1].key == "hold", "폴백: 궁지 → 사수", ph.steps[1] and tostring(ph.steps[1].key))
	-- 생존 국면이라도 다른 단계가 서면 그쪽이 우선(자세는 폴백일 뿐)
	local Se = baseS{ immediate = 1, border_enemies = { "e2" }, war_set = { e2 = true },
		strat = { enemy = { e2 = { regions = 2 } }, provinces = {}, armies = {}, endgame = { active = {} } } }
	ok(T.plan_generate(Se, "궁지").steps[1].kind == "elim", "폴백: 실제 단계가 있으면 자세로 안 떨어짐")
	-- 영구 호드(점령 불가) → 약탈 자세
	local Sr = baseS{ regions = 0, my_regions = 0, can_capture = false,
		strat = { enemy = {}, provinces = {}, armies = {}, endgame = { active = {} } } }
	local pr = T.plan_generate(Sr, "초반 정착")
	ok(pr.steps[1] and pr.steps[1].key == "raid", "폴백: 영구 호드 → 약탈", pr.steps[1] and tostring(pr.steps[1].key))
end
do
	-- ② 활주로: 음수 국고 / 이번 턴 / 정상 3분기
	ok(T.runway_phrase({ broke = true }) == "국고가 이미 마이너스입니다", "활주로: 마이너스 국고")
	ok(T.runway_phrase({ runway = 0 }) == "이 추세면 이번 턴에 바닥납니다", "활주로: 0턴 축약")
	ok(T.runway_phrase({ runway = 0 }, true) == "이 추세면 이번 턴에 국고가 바닥납니다", "활주로: 0턴 완문")
	ok(T.runway_phrase({ runway = 4 }) == "이 추세면 ~4턴 내 고갈됩니다", "활주로: 정상 축약")
	ok(T.runway_phrase(nil) == nil and T.runway_phrase({}) == nil, "활주로: 미상이면 무문구")
	-- project: 국고 음수면 runway 대신 broke
	local Sb = baseS{ treasury = -1200, income = 1000, net = -400, losing = true,
		trend = { dt = 2, treasury = -900, regions = 0, income = -50 } }
	local Pb = T.project(Sb)
	ok(Pb.broke == true and Pb.runway == nil, "투영: 음수 국고 → broke(음수 활주로 금지)", tostring(Pb.runway))
	Sb.proj = Pb
	local _, _, _, prose_b, brief_b = run(Sb)
	ok(not prose_b:find("~-", 1, true) and has(prose_b, "국고가 이미 마이너스입니다"), "투영: 산문에 음수턴 없음", prose_b:match("[^\n]*마이너스[^\n]*"))
	ok(has(brief_b, "국고 마이너스"), "투영: 브리핑 표기")
	-- 국고 30 / 턴당 -400 → 0턴
	local S0 = baseS{ treasury = 30, income = 1000, net = -400, losing = true,
		trend = { dt = 2, treasury = -800, regions = 0, income = 0 } }
	S0.proj = T.project(S0)
	ok(S0.proj.runway == 0, "투영: 1턴 미만 → 0", tostring(S0.proj.runway))
	local _, _, _, prose_0, brief_0 = run(S0)
	ok(has(prose_0, "이번 턴에") and not has(prose_0, "~0턴"), "투영: 0턴 문구 교정", prose_0:match("【국면[^\n]*"))
	ok(has(brief_0, "이번 턴 고갈") and not has(brief_0, "고갈 ~0턴"), "투영: 브리핑 0턴 표기", brief_0:match("🔮[^\n]*"))
end
do
	-- ③ 수입 0 → buffer 999 센티넬이 판단·표시로 새지 않는가
	local Sz = baseS{ regions = 0, my_regions = 0, provinces = 0, generals = 1,
		treasury = 2500, income = 0, net = 0, losing = false }
	local D, cand, _, prose, brief = run(Sz)
	ok(D.buffer_known == false, "센티넬: 수입0 → buffer 미상 표시")
	local eco
	for _, c in ipairs(cand) do if c.key == "economy" then eco = c end end
	ok(not (eco and has(table.concat(eco.reasons, ";"), "금고 과다")), "센티넬: 무일푼에 '금고 과다' 금지",
		eco and table.concat(eco.reasons, ";"))
	ok(not has(prose, "금고 과다"), "센티넬: 산문에도 없음")
	ok(has(brief, "재정버퍼 미상(수입 0)") and not has(brief, "재정버퍼 충분"), "센티넬: 브리핑 '미상' 표기", brief:match("파생[^\n]*"))
	-- 수입 정상 + 실제 과적재는 그대로 유지(과교정 방지)
	local Sr = baseS{ treasury = 60000, income = 3000, net = 2000 }
	local _, cand2 = run(Sr)
	local eco2
	for _, c in ipairs(cand2) do if c.key == "economy" then eco2 = c end end
	ok(eco2 and has(table.concat(eco2.reasons, ";"), "금고 과다"), "센티넬: 진짜 과적재는 유지")
end
do
	-- ④ 수집 실패 신호: key_set이 실패를 ok=false로 알리는가(빈 집합=평온 위장 방지)
	local set, cnt, kok = T.key_set(function() error("boom") end)
	ok(kok == false and cnt == 0, "수집: 조회 실패 → ok=false", tostring(kok))
	local set2, cnt2, kok2 = T.key_set(function()
		return { num_items = function() return 2 end,
			item_at = function(_, i) return { name = function() return "f" .. i end } end }
	end)
	ok(kok2 == true and cnt2 == 2 and set2.f0 and set2.f1, "수집: 정상 조회 → ok=true+집합")
	-- 산문 신뢰성 줄이 새 라벨(국경/전쟁)을 그대로 실어내는가
	local Sf = baseS{ health = { "국경", "전쟁" } }
	local _, _, _, prose_f = run(Sf)
	ok(has(prose_f, "국경·전쟁 정보를 읽지 못했습니다"), "수집: 신뢰성 줄에 국경·전쟁", prose_f:match("⚠[^\n]*"))
end
do
	-- ⑤ 영토0 앵커 스캔 소비: 첫 정착지 후보 지목
	local Ss = baseS{ regions = 0, my_regions = 0, provinces = 0, generals = 1,
		threats = { sieges = {}, threatened = {}, targets = {}, my_field = {},
			settle = { { region = "reg_bad", owner = "own_a", at_war = true, suit = "suitability_verypoor" },
			           { region = "reg_good", owner = "own_b", at_war = true, suit = "suitability_good" } } } }
	Ss.plan = T.plan_generate(Ss, "초반 정착")
	local pl = table.concat(T.plan_prose_lines(Ss), "\n")
	ok(has(pl, "거점 확보") and has(pl, "인근 후보: Good"), "호드: 첫 정착지 후보 지목", pl:match("①[^\n]*"))
	-- 전시 상대가 없으면 비전시 후보 + 선전포고 경고
	local Sn = baseS{ regions = 0, my_regions = 0, provinces = 0, generals = 1,
		threats = { sieges = {}, threatened = {}, targets = {}, my_field = {},
			settle = { { region = "reg_n", owner = "own_c", at_war = false, suit = "suitability_good" } } } }
	Sn.plan = T.plan_generate(Sn, "초반 정착")
	local pl2 = table.concat(T.plan_prose_lines(Sn), "\n")
	ok(has(pl2, "선전포고 필요"), "호드: 비전시 후보엔 선전포고 경고", pl2:match("①[^\n]*"))
	-- 부적합만 있으면 그거라도 지목하되 약탈 권고
	local Sp = baseS{ regions = 0, my_regions = 0, provinces = 0, generals = 1,
		threats = { sieges = {}, threatened = {}, targets = {}, my_field = {},
			settle = { { region = "reg_bad", owner = "own_a", at_war = true, suit = "suitability_verypoor" } } } }
	Sp.plan = T.plan_generate(Sp, "초반 정착")
	ok(has(table.concat(T.plan_prose_lines(Sp), "\n"), "기후 부적합 — 약탈 권장"), "호드: 부적합 후보는 약탈 권고")
	-- 후보가 없으면 기존 일반 문구 유지(무예외)
	local Se = baseS{ regions = 0, my_regions = 0, provinces = 0, generals = 1 }
	Se.plan = T.plan_generate(Se, "초반 정착")
	ok(has(table.concat(T.plan_prose_lines(Se), "\n"), "첫 정착지를 점령해"), "호드: 후보 없으면 일반 문구")
	-- 계획 ①이 지목한 후보를 '확장 기회' 줄이 되풀이하지 않는가(중복 방송 억제)
	local Sd = baseS{ regions = 0, my_regions = 0, provinces = 0, generals = 1,
		threats = { sieges = {}, threatened = {}, my_field = {},
			targets = { { region = "reg_good", owner = "own_b", my_border = "a", near = true, suit = "suitability_good" } },
			settle = { { region = "reg_good", owner = "own_b", at_war = true, suit = "suitability_good" } } } }
	Sd.plan = T.plan_generate(Sd, "초반 정착")
	local _, _, _, prose_d = run(Sd)
	ok(has(prose_d, "인근 후보: Good") and not has(prose_d, "확장 기회"), "호드: 계획이 지목한 후보는 확장기회 줄에서 중복 억제",
		prose_d:match("확장[^\n]*"))
	-- 영토 0이면 '국경 평온'이라는 공허한 말 대신 실상
	ok(has(prose_d, "지킬 국경도 없") and not has(prose_d, "국경은 평온"), "호드: 공허한 '국경 평온' 제거", prose_d:match("종합[^\n]*") or prose_d:match("[^\n]*턴 현재[^\n]*"))
	ok(not has(prose_d, "국경 평온 — 성장 적기") and not has(prose_d, "국경 평온, 성장 적기"), "호드: 경제 근거도 '국경 평온' 배제", prose_d:match("기회[^\n]*") or prose_d:match("보강[^\n]*"))
	-- 브리핑 ⚔ 지도 줄에 정착후보 노출 + 목록 상한
	local _, _, _, _, brief = run(Ss)
	ok(has(brief, "정착후보=") and has(brief, "Good"), "호드: 브리핑 정착후보 표기", brief:match("⚔[^\n]*"))
	local many = { sieges = {}, threatened = {}, my_field = {}, targets = {} }
	for i = 1, 20 do many.targets[i] = { region = "r" .. i, owner = "o", my_border = "b", near = true } end
	local _, _, _, _, brief2 = run(baseS{ threats = many })
	ok(has(brief2, "외 12"), "지도 줄: 8개 + '외 N' 상한", brief2:match("⚔[^\n]*"))
end

do
	-- ⑤-2 앵커 스캔 자체(게임 API 스텁) — 영토0에서 실제로 후보가 잡히는지.
	--   ※ 스텁은 형태만 재현한다. 실제 인터페이스 동작은 인게임 프루프로만 확정(짐작 금지).
	local function mklist(t) return { num_items = function() return #t end, item_at = function(_, i) return t[i + 1] end } end
	local function mkregion(name, owner, opts)
		opts = opts or {}
		local r
		r = {
			name = function() return name end,
			is_null_interface = function() return false end,
			is_abandoned = function() return opts.abandoned == true end,
			owning_faction = function() return { is_null_interface = function() return false end, name = function() return owner end } end,
			adjacent_region_list = function() return mklist(opts.adj or {}) end,
			settlement = function() return { get_climate = function() return opts.climate or "ok" end } end,
			garrison_residence = function() return nil end,
		}
		return r
	end
	local nbr1 = mkregion("reg_enemy", "foe")                        -- 전쟁 중 적 소유
	local nbr2 = mkregion("reg_neutral", "neu")                      -- 비전시
	local nbr3 = mkregion("reg_ruin", "gone", { abandoned = true })  -- 폐허(제외 대상)
	local anchor = mkregion("reg_anchor", "foe", { adj = { nbr1, nbr2, nbr3 }, climate = "bad" })
	local ch = { has_region = function() return true end, region = function() return anchor end }
	local mf = { has_general = function() return true end, is_armed_citizenry = function() return false end,
		general_character = function() return ch end }
	local f = {
		region_list = function() return mklist({}) end,              -- 영토 0
		military_force_list = function() return mklist({ mf }) end,
		get_climate_suitability = function(_, c) return (c == "bad") and "suitability_verypoor" or "suitability_good" end,
	}
	local Tt = T.gather_threats(f, { foe = true }, { "foe" }, "me")
	ok(Tt.ok == true, "앵커: 수집 성공")
	local names, byname = {}, {}
	for _, c in ipairs(Tt.settle or {}) do names[#names + 1] = c.region; byname[c.region] = c end
	table.sort(names)
	ok(#names == 3 and byname.reg_anchor and byname.reg_enemy and byname.reg_neutral,
		"앵커: 서 있는 지역+인접 후보 수집", table.concat(names, ","))
	ok(byname.reg_ruin == nil, "앵커: 폐허 제외(식민 가능 미실측)")
	ok(byname.reg_enemy and byname.reg_enemy.at_war == true and byname.reg_neutral.at_war == false, "앵커: 전시/비전시 구분")
	ok(byname.reg_anchor and byname.reg_anchor.suit == "suitability_verypoor", "앵커: 기후 적합성 부착", byname.reg_anchor and tostring(byname.reg_anchor.suit))
	local tg = {}
	for _, t in ipairs(Tt.targets or {}) do tg[t.region] = t end
	ok(tg.reg_enemy and tg.reg_enemy.near == true and tg.reg_neutral == nil, "앵커: 전쟁 상대만 공격 표적 + 근접 판정")
	ok(Tt.my_field["reg_anchor"] == true, "앵커: 내 야전군 위치 기록")
	-- 영토가 있으면 앵커 스캔은 돌지 않는다(기존 경로 불변)
	local owned = mkregion("reg_mine", "me", { adj = { nbr1 } })
	local f2 = { region_list = function() return mklist({ owned }) end,
		military_force_list = function() return mklist({ mf }) end,
		get_climate_suitability = function() return "suitability_good" end }
	local T2 = T.gather_threats(f2, { foe = true }, { "foe" }, "me")
	ok(#(T2.settle or {}) == 0, "앵커: 영토 있으면 미작동(기존 경로 유지)", #(T2.settle or {}))
end

-- ── 리포트 출력 ───────────────────────────────────────────────────────
local report = table.concat(R.lines, "\n")
local fh = real_open(ROOT .. "/test/out_brain_report.txt", "w")
if fh then fh:write(report .. string.format("\n\nTOTAL %d  PASS %d  FAIL %d\n", R.pass + R.fail, R.pass, R.fail)); fh:close() end
print(string.format("TOTAL %d  PASS %d  FAIL %d", R.pass + R.fail, R.pass, R.fail))
if R.fail > 0 then
	for _, l in ipairs(R.lines) do if l:sub(1, 4) == "FAIL" then print(l) end end
	os.exit(1)
end
os.exit(0)
