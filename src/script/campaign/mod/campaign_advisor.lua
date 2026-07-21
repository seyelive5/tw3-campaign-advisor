--[[===========================================================================
  TW3 캠페인 어드바이저 — Phase 1 / Step 2
  ---------------------------------------------------------------------------
  목적 : 이 스크립트가 "캠페인 시작 시 자동 로드"되는지 증명한다.
  범위 : 읽기 전용. 게임 상태를 바꾸는 행동은 전혀 하지 않는다.
  로드 : 바닐라 lib_mod_loader.lua 가 로드된 모든 pack의
         script\campaign\mod\*.lua 를 캠페인 시작 시 스캔·실행한다.
         (8.1.1 바닐라도 이 폴더에 battle_logging.lua 등 7개를 넣어 사용)
  확인 : out() 출력은 인게임 Lua 콘솔(모딩 개발툴)과 script 로그에 남는다.
=============================================================================]]

-- [1] top-level 실행 증거 — 의존성 0 (파일이 실행되기만 하면 무조건 찍힘)
out("###################################################################")
out("[CAMPAIGN_ADVISOR] STEP2: 스크립트 파일 로드/실행됨 (top-level)")
out("###################################################################")

-- [2] 캠페인 컨텍스트 증거 — first tick 시점에 campaign_manager 사용 가능 확인
local cm = get_campaign_manager()

cm:add_first_tick_callback(
	function()
		local ok, faction_name = pcall(function() return cm:get_local_faction_name() end)
		out("[CAMPAIGN_ADVISOR] STEP2: first tick 도달 — 캠페인 컨텍스트 준비됨")
		out("[CAMPAIGN_ADVISOR] STEP2: 로컬 팩션 = " .. tostring(ok and faction_name or "(조회 실패)"))
	end
)
