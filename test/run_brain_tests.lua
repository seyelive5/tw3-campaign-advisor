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
		war_count = 1, border_enemies = {}, border_others = { "wh_main_brt_bretonnia" },
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
	ok(has(prose, "화친이 성사 가능한 상대"), "산문: 화친 가능")
	ok(has(prose, "군사동맹이 가능한 상대"), "산문: 동맹 가능")
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
