--[[===========================================================================
  TW3 캠페인 어드바이저 — Phase 1 / Step 3 (v4: 커스텀 UI 버튼 + 클릭 감지)
  ---------------------------------------------------------------------------
  로더 계약(실측): NewSession 때 이 파일 top-level 실행 → first tick 때
  core:execute_mods 가 "파일명과 동일한 전역 함수" campaign_advisor() 호출.
  ⇒ UI 로직은 그 전역 함수 안에서 수행(cm/core 전역 준비 완료 시점).

  이번 단계 목표: 캠페인 HUD에 커스텀 버튼 1개를 붙이고, 클릭을 감지한다.
  모든 API는 tw_autogen + ui3.pack 인덱스 실측으로 확인(짐작 아님):
    - root = core:get_ui_root()                     (campaign/core.lua:12)
    - addr = root:CreateComponent(id, template)     (uicomponent.lua:241)
    - btn  = UIComponent(addr)                       (global.lua:833)
    - 템플릿 "ui/templates/round_medium_button"      (ui3.pack 인덱스 실측)
    - 클릭 이벤트 "ComponentLClickUp",               (campaign_ui_manager.lua:261)
      context.string = 클릭된 컴포넌트 id            (campaign/core.lua:486)
  범위: 읽기 전용. 상태 변경 없음.

  검증 전략: 화면 확인이 애매할 수 있으므로 생성 결과(좌표/크기)와 클릭을
  모두 증거 파일에 기록해 파일만으로도 성공/실패를 판정한다.
=============================================================================]]

local PROOF_PATH     = "C:/Users/veria/tw3_advisor_proof.txt"
local BUTTON_ID      = "advisor_recommend_button"
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
proof("STEP3 파일 로드됨 (NewSession/top-level). io.open = " .. tostring(io and io.open), false)

-- 중복 실행 가드(로더가 두 번 부르면 같은 id 재생성 에러 방지).
local g_done = false

-- 클릭 리스너: 우리 버튼 id 가 클릭되면 증거 기록.
local function register_click_listener()
	core:add_listener(
		"advisor_button_click",
		"ComponentLClickUp",
		function(context) return context.string == BUTTON_ID end,  -- 조건
		function(context)                                          -- 콜백
			local ok, fac = pcall(function() return cm:get_local_faction_name() end)
			proof("STEP3 >>> 버튼 클릭됨! 로컬 팩션 = " .. tostring(ok and fac or "(조회실패)"), true)
		end,
		true  -- persist
	)
	proof("STEP3 클릭 리스너 등록 (event=ComponentLClickUp, id=" .. BUTTON_ID .. ")", true)
end

-- 버튼 생성: ui root 자식으로 템플릿에서 생성 → 보이게 위치/최상위/이동가능.
local function create_advisor_button()
	local ok, err = pcall(function()
		local root = core:get_ui_root()
		local addr = root:CreateComponent(BUTTON_ID, BUTTON_TEMPLATE)
		if not addr then
			proof("STEP3 !!! CreateComponent 반환 nil — 템플릿 경로/로드 확인 필요", true)
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
			"STEP3 버튼 생성 OK id=%s pos=(%d,%d) size=(%dx%d) rootDim=(%dx%d)",
			tostring(btn:Id()), x, y, w, h, rw, rh), true)
	end)
	if not ok then
		proof("STEP3 !!! 버튼 생성 예외: " .. tostring(err), true)
	end
end

-- [first tick] 로더가 호출하는 전역 함수(파일명 동일). cm/core 전역 준비 완료.
function campaign_advisor()
	if g_done then proof("STEP3 campaign_advisor() 중복 호출 — skip", true); return end
	g_done = true
	register_click_listener()
	create_advisor_button()
	proof("STEP3 campaign_advisor() 실행 완료 (first tick).", true)
end
