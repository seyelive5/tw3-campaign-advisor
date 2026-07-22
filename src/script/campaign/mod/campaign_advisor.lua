--[[===========================================================================
  TW3 캠페인 어드바이저 — Phase 1 / Step 4 (v5: 클릭 시 상태 덤프)
  ---------------------------------------------------------------------------
  로더 계약(실측): NewSession 때 top-level 실행 → first tick 때
  core:execute_mods 가 전역 함수 campaign_advisor() 호출.

  이번 단계: Step3의 버튼/클릭 리스너는 유지하고, 클릭 콜백을 "현재 캠페인
  상태 덤프"로 확장한다(읽기 전용). 사용자가 인게임 UI 숫자와 대조해 검증.

  덤프 항목 & 근거 API (tw_autogen script_interfaces.lua / campaign_manager.lua 실측):
    - 로컬 팩션 객체 : cm:get_local_faction(true)          (campaign_manager:334)
    - 턴            : cm:turn_number()                     (campaign_manager:467)
    - 재정          : faction:treasury/income/net_income/losing_money  (695~733)
    - 영토          : faction:region_list():num_items(), num_provinces (705/687)
    - 군대          : faction:military_force_list():num_items(), num_generals (763/793)
    - 위협/관계     : faction:at_war(), factions_at_war_with(), factions_met() (783/791/685)
    - 리스트 순회   : list:num_items() + list:item_at(i)   (0-based, 1089/1091 등)
  주의: faction:name() 은 로컬라이즈 안 된 "키"(예 wh_main_emp_empire) 반환.
        화면 텍스트는 영어 툴팁만(한글 글리프 미보장). 덤프는 파일(io)에 기록.
  범위: 읽기 전용. 상태 변경 없음.
=============================================================================]]

local PROOF_PATH      = "C:/Users/veria/tw3_advisor_proof.txt"
local BUTTON_ID       = "advisor_recommend_button"
local BUTTON_TEMPLATE = "ui/templates/round_medium_button"  -- ui3.pack 실측 경로

-- out() + (io 가능하면) 파일 기록. 둘 다 pcall 보호.
local function proof(msg, append)
	pcall(function() out("[CAMPAIGN_ADVISOR] " .. msg) end)
	pcall(function()
		if io and io.open then
			local f = io.open(PROOF_PATH, append and "a" or "w")
			if f then f:write(msg .. "\n"); f:close() end
		end
	end)
end

-- [top-level] NewSession 로드 증거. 파일 새로 생성(truncate).
proof("STEP4 파일 로드됨 (NewSession/top-level). io.open = " .. tostring(io and io.open), false)

local g_done  = false   -- 버튼 중복 생성 가드
local g_click = 0        -- 클릭 카운터(파일에서 회차 구분)

-- 단일 getter 안전 실행: 실패해도 전체 덤프가 죽지 않게.
local function S(fn)
	local ok, v = pcall(fn)
	if ok then return tostring(v) else return "(ERR)" end
end

-- 팩션 리스트 요약: "N개 [키1, 키2, ...]" (cap 초과분은 ... 로 생략).
local function list_summary(list_getter, cap)
	local ok, s = pcall(function()
		local list = list_getter()
		local n = list:num_items()
		local lim = math.min(n, cap or 8)
		local names = {}
		for i = 0, lim - 1 do names[#names + 1] = list:item_at(i):name() end
		return string.format("%d개 [%s%s]", n, table.concat(names, ", "), (n > lim and ", ..." or ""))
	end)
	return ok and s or "(ERR)"
end

-- 클릭 시: 현재 상태를 파일에 블록으로 덤프.
local function dump_state()
	g_click = g_click + 1
	local f = nil
	pcall(function() f = cm:get_local_faction(true) end)

	local lines = {
		string.format("====== STEP4 상태 덤프 #%d (turn %s) ======", g_click, S(function() return cm:turn_number() end)),
		"팩션 name: "   .. S(function() return f:name() end),
		"재정 treasury: " .. S(function() return f:treasury() end),
		string.format("수입 income: %s / 순수입 net_income: %s / 적자 losing_money: %s",
			S(function() return f:income() end), S(function() return f:net_income() end), S(function() return f:losing_money() end)),
		string.format("영토 regions: %s / 프로빈스 provinces: %s",
			S(function() return f:region_list():num_items() end), S(function() return f:num_provinces() end)),
		string.format("군대 armies: %s / 장군 generals: %s",
			S(function() return f:military_force_list():num_items() end), S(function() return f:num_generals() end)),
		"전쟁중 at_war: "        .. S(function() return f:at_war() end),
		"교전 factions_at_war_with: " .. list_summary(function() return f:factions_at_war_with() end, 8),
		"조우 factions_met: "    .. list_summary(function() return f:factions_met() end, 12),
		"=========================================",
	}
	proof(table.concat(lines, "\n"), true)
end

-- 클릭 리스너: 우리 버튼 id 가 클릭되면 상태 덤프.
local function register_click_listener()
	core:add_listener(
		"advisor_button_click",
		"ComponentLClickUp",
		function(context) return context.string == BUTTON_ID end,  -- 조건
		function(context) dump_state() end,                        -- 콜백
		true  -- persist
	)
	proof("STEP4 클릭 리스너 등록 (event=ComponentLClickUp, id=" .. BUTTON_ID .. ")", true)
end

-- 버튼 생성: ui root 자식으로 템플릿에서 생성 → 보이게 위치/최상위/이동가능.
local function create_advisor_button()
	local ok, err = pcall(function()
		local root = core:get_ui_root()
		local addr = root:CreateComponent(BUTTON_ID, BUTTON_TEMPLATE)
		if not addr then
			proof("STEP4 !!! CreateComponent 반환 nil — 템플릿 경로/로드 확인 필요", true)
			return
		end
		local btn = UIComponent(addr)

		local rw, rh = root:Dimensions()
		btn:MoveTo(math.floor(rw * 0.45), 90)   -- 상단 중앙 근처(탑바 아래)
		btn:SetVisible(true)
		btn:SetInteractive(true)
		btn:SetDisabled(false)
		btn:RegisterTopMost()                    -- 다른 패널 위로
		btn:SetMoveable(true)                    -- 안 보이면 드래그로 확인
		pcall(function() btn:SetTooltipText("Advisor: what to do now (click)", "", true) end)

		local x, y = btn:Position()
		local w, h = btn:Dimensions()
		proof(string.format(
			"STEP4 버튼 생성 OK id=%s pos=(%d,%d) size=(%dx%d) rootDim=(%dx%d)",
			tostring(btn:Id()), x, y, w, h, rw, rh), true)
	end)
	if not ok then
		proof("STEP4 !!! 버튼 생성 예외: " .. tostring(err), true)
	end
end

-- [first tick] 로더가 호출하는 전역 함수(파일명 동일). cm/core 전역 준비 완료.
function campaign_advisor()
	if g_done then proof("STEP4 campaign_advisor() 중복 호출 — skip", true); return end
	g_done = true
	register_click_listener()
	create_advisor_button()
	proof("STEP4 campaign_advisor() 실행 완료 (first tick). 버튼을 클릭하면 상태가 덤프됩니다.", true)
end
