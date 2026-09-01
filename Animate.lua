--!strict
--[[
    Client-Side Mobile Cinematic Camera & Keyframe System
    Place in StarterPlayer -> StarterPlayerScripts
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
local CurrentCamera = Workspace.CurrentCamera :: Camera

--------------------------------------------------------------------------------
-- TOUCH CONTROLS TOGGLE
--------------------------------------------------------------------------------
local function SetTouchControlsVisible(visible: boolean)
	local touchGui = PlayerGui:FindFirstChild("TouchGui")
	if touchGui and touchGui:IsA("ScreenGui") then
		touchGui.Enabled = visible
	end

	pcall(function()
		local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
		if playerScripts then
			local playerModule = playerScripts:FindFirstChild("PlayerModule")
			if playerModule then
				local controls = require(playerModule :: ModuleScript):GetControls()
				if visible then
					controls:Enable()
				else
					controls:Disable()
				end
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- TYPES & STATE MANAGEMENT
--------------------------------------------------------------------------------
type SystemState = "IDLE" | "PLACEMENT" | "POV_EDIT" | "PLAYBACK"

type KeyframeData = {
	Id: number,
	Order: number,
	CFrame: CFrame,
	Speed: number,
	StopTime: number,
	MarkerPart: Part,
	ArrowPart: WedgePart,
	Attachment: Attachment,
	Billboard: BillboardGui,
	TextLabel: TextLabel,
}

local State: SystemState = "IDLE"
local Keyframes: { KeyframeData } = {}
local Beams: { Beam } = {}

local SelectedIndices: { [number]: boolean } = {}

local DefaultSpeed: number = 15.0
local DefaultStopTime: number = 1.0

local SavedCamCFrame: CFrame = CFrame.identity
local SavedCamType: Enum.CameraType = Enum.CameraType.Custom
local SavedCamSubject: Instance? = nil

local ScreenGui: ScreenGui
local MainFrame: Frame
local POVOverlay: Frame
local POVTouchArea: Frame
local PlaybackOverlay: Frame
local KeyframeFolder: Folder
local DotScrollList: ScrollingFrame

local PovYaw: number = 0
local PovPitch: number = 0
local PovMoveVector: Vector3 = Vector3.zero
local PovRenderConn: RBXScriptConnection? = nil
local PovPrimaryIdx: number? = nil
local PovRelativeOffsets: { [number]: CFrame } = {}

local ExitPOVMode: () -> ()
local StopCinematic: () -> ()
local ClearAllKeyframes: () -> ()

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS FOR MULTI-SELECTION
--------------------------------------------------------------------------------
local function GetSelectedIndicesList(): { number }
	local list: { number } = {}
	for idx, isSelected in pairs(SelectedIndices) do
		if isSelected and Keyframes[idx] then
			table.insert(list, idx)
		end
	end
	table.sort(list)
	return list
end

local function GetSelectedCount(): number
	local count = 0
	for idx, isSelected in pairs(SelectedIndices) do
		if isSelected and Keyframes[idx] then
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- WORKSPACE & VISUAL MARKER SETUP
--------------------------------------------------------------------------------
KeyframeFolder = Workspace:FindFirstChild("CinematicKeyframesContainer") :: Folder
if not KeyframeFolder then
	KeyframeFolder = Instance.new("Folder")
	KeyframeFolder.Name = "CinematicKeyframesContainer"
	KeyframeFolder.Parent = Workspace
end

local function ClearPathBeams()
	for _, beam in ipairs(Beams) do
		beam:Destroy()
	end
	table.clear(Beams)
end

local function UpdatePathVisuals()
	ClearPathBeams()
	if #Keyframes < 2 then
		return
	end

	for i = 1, #Keyframes - 1 do
		local kfA = Keyframes[i]
		local kfB = Keyframes[i + 1]

		local beam = Instance.new("Beam")
		beam.Name = "PathBeam_" .. i
		beam.Attachment0 = kfA.Attachment
		beam.Attachment1 = kfB.Attachment
		beam.Width0 = 0.2
		beam.Width1 = 0.2
		beam.Color = ColorSequence.new(Color3.fromRGB(0, 170, 255))
		beam.FaceCamera = true
		beam.Transparency = NumberSequence.new(0.3)
		beam.Parent = KeyframeFolder
		table.insert(Beams, beam)
	end
end

local function UpdateMarkerAppearance(kf: KeyframeData, isSelected: boolean)
	if isSelected then
		kf.MarkerPart.Color = Color3.fromRGB(40, 180, 80)
		kf.ArrowPart.Color = Color3.fromRGB(100, 255, 140)
		kf.TextLabel.TextColor3 = Color3.fromRGB(40, 180, 80)
	else
		kf.MarkerPart.Color = Color3.fromRGB(0, 170, 255)
		kf.ArrowPart.Color = Color3.fromRGB(255, 255, 255)
		kf.TextLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	end
end

local function RefreshKeyframeIndices()
	for index, kf in ipairs(Keyframes) do
		kf.Order = index
		kf.MarkerPart.Name = "KeyframeMarker_" .. index
		kf.TextLabel.Text = "KF #" .. index
		UpdateMarkerAppearance(kf, SelectedIndices[index] == true)
	end
	UpdatePathVisuals()
end

local function CreateVisualMarker(cf: CFrame, order: number): KeyframeData
	local marker = Instance.new("Part")
	marker.Name = "KeyframeMarker_" .. order
	marker.Shape = Enum.PartType.Ball
	marker.Size = Vector3.new(1.2, 1.2, 1.2)
	marker.CFrame = cf
	marker.Anchored = true
	marker.CanCollide = false
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.fromRGB(0, 170, 255)
	marker.Parent = KeyframeFolder

	local arrow = Instance.new("WedgePart")
	arrow.Name = "DirectionArrow"
	arrow.Size = Vector3.new(0.6, 0.6, 1.2)
	arrow.CFrame = cf * CFrame.new(0, 0, -1.1) * CFrame.Angles(0, math.rad(180), 0)
	arrow.Anchored = true
	arrow.CanCollide = false
	arrow.Material = Enum.Material.SmoothPlastic
	arrow.Color = Color3.fromRGB(255, 255, 255)
	arrow.Parent = KeyframeFolder

	local attachment = Instance.new("Attachment")
	attachment.Parent = marker

	local bb = Instance.new("BillboardGui")
	bb.Name = "MarkerBillboard"
	bb.Size = UDim2.new(0, 80, 0, 30)
	bb.StudsOffset = Vector3.new(0, 1.8, 0)
	bb.AlwaysOnTop = true
	bb.Adornee = marker
	bb.Parent = marker

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "KF #" .. order
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.2
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.Parent = bb

	local kfData: KeyframeData = {
		Id = tick() + math.random(),
		Order = order,
		CFrame = cf,
		Speed = DefaultSpeed,
		StopTime = DefaultStopTime,
		MarkerPart = marker,
		ArrowPart = arrow,
		Attachment = attachment,
		Billboard = bb,
		TextLabel = label,
	}

	return kfData
end

local function UpdateKeyframeTransform(kf: KeyframeData, newCFrame: CFrame)
	kf.CFrame = newCFrame
	kf.MarkerPart.CFrame = newCFrame
	kf.ArrowPart.CFrame = newCFrame * CFrame.new(0, 0, -1.1) * CFrame.Angles(0, math.rad(180), 0)
end

local function SetVisualsVisible(visible: boolean)
	KeyframeFolder.Parent = visible and Workspace or nil
end

--------------------------------------------------------------------------------
-- UI BUILDER
--------------------------------------------------------------------------------
local function BuildUI()
	ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Name = "CinematicCameraGui"
	ScreenGui.ResetOnSpawn = false
	ScreenGui.DisplayOrder = 100
	ScreenGui.Parent = PlayerGui

	MainFrame = Instance.new("Frame")
	MainFrame.Name = "MainFrame"
	MainFrame.Size = UDim2.new(0, 300, 0, 440)
	MainFrame.Position = UDim2.new(0.05, 0, 0.12, 0)
	MainFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	MainFrame.BackgroundTransparency = 0.15
	MainFrame.BorderSizePixel = 0
	MainFrame.ClipsDescendants = true
	MainFrame.Parent = ScreenGui

	local mainCorner = Instance.new("UICorner")
	mainCorner.CornerRadius = UDim.new(0, 12)
	mainCorner.Parent = MainFrame

	local mainStroke = Instance.new("UIStroke")
	mainStroke.Color = Color3.fromRGB(60, 65, 75)
	mainStroke.Thickness = 1.5
	mainStroke.Parent = MainFrame

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 40)
	header.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
	header.BorderSizePixel = 0
	header.Parent = MainFrame

	Instance.new("UICorner", header).CornerRadius = UDim.new(0, 12)

	local headerClose = Instance.new("TextButton")
	headerClose.Name = "HeaderClose"
	headerClose.Size = UDim2.new(0, 28, 0, 28)
	headerClose.Position = UDim2.new(0, 8, 0.5, -14)
	headerClose.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
	headerClose.Text = "✕"
	headerClose.TextColor3 = Color3.fromRGB(255, 255, 255)
	headerClose.Font = Enum.Font.GothamBold
	headerClose.TextSize = 14
	headerClose.Parent = header
	Instance.new("UICorner", headerClose).CornerRadius = UDim.new(0, 6)

	local headerTitle = Instance.new("TextLabel")
	headerTitle.Size = UDim2.new(1, -70, 1, 0)
	headerTitle.Position = UDim2.new(0, 42, 0, 0)
	headerTitle.BackgroundTransparency = 1
	headerTitle.Text = "CAM EDITOR (MOBILE)"
	headerTitle.TextColor3 = Color3.fromRGB(230, 235, 245)
	headerTitle.Font = Enum.Font.GothamBold
	headerTitle.TextSize = 12
	headerTitle.TextXAlignment = Enum.TextXAlignment.Left
	headerTitle.Parent = header

	local dragging = false
	local dragStart = Vector2.zero
	local startPos = UDim2.new()

	header.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			dragStart = input.Position
			startPos = MainFrame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			local delta = input.Position - dragStart
			MainFrame.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)

	local content = Instance.new("Frame")
	content.Size = UDim2.new(1, -20, 1, -50)
	content.Position = UDim2.new(0, 10, 0, 45)
	content.BackgroundTransparency = 1
	content.Parent = MainFrame

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = content

	local function CreateButton(text: string, color: Color3, layoutOrder: number): TextButton
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, 0, 0, 32)
		btn.BackgroundColor3 = color
		btn.Text = text
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 11
		btn.AutoButtonColor = true
		btn.LayoutOrder = layoutOrder
		btn.Parent = content

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = btn

		return btn
	end

	local btnPlacement = CreateButton("PLACEMENT MODE: OFF", Color3.fromRGB(45, 50, 60), 1)
	local btnPOV = CreateButton("SET POSITION / EDIT SELECTED", Color3.fromRGB(50, 90, 160), 2)

	local selectRow = Instance.new("Frame")
	selectRow.Size = UDim2.new(1, 0, 0, 30)
	selectRow.BackgroundTransparency = 1
	selectRow.LayoutOrder = 3
	selectRow.Parent = content

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, 4)
	rowLayout.Parent = selectRow

	local btnSelectAll = Instance.new("TextButton")
	btnSelectAll.Size = UDim2.new(0.33, -3, 1, 0)
	btnSelectAll.BackgroundColor3 = Color3.fromRGB(0, 140, 180)
	btnSelectAll.Text = "SELECT ALL"
	btnSelectAll.TextColor3 = Color3.fromRGB(255, 255, 255)
	btnSelectAll.Font = Enum.Font.GothamBold
	btnSelectAll.TextSize = 10
	btnSelectAll.Parent = selectRow
	Instance.new("UICorner", btnSelectAll).CornerRadius = UDim.new(0, 6)

	local btnDelete = Instance.new("TextButton")
	btnDelete.Size = UDim2.new(0.33, -3, 1, 0)
	btnDelete.BackgroundColor3 = Color3.fromRGB(160, 50, 50)
	btnDelete.Text = "DELETE"
	btnDelete.TextColor3 = Color3.fromRGB(255, 255, 255)
	btnDelete.Font = Enum.Font.GothamBold
	btnDelete.TextSize = 10
	btnDelete.Parent = selectRow
	Instance.new("UICorner", btnDelete).CornerRadius = UDim.new(0, 6)

	local btnClearAll = Instance.new("TextButton")
	btnClearAll.Size = UDim2.new(0.34, -2, 1, 0)
	btnClearAll.BackgroundColor3 = Color3.fromRGB(180, 80, 20)
	btnClearAll.Text = "CLEAR ALL"
	btnClearAll.TextColor3 = Color3.fromRGB(255, 255, 255)
	btnClearAll.Font = Enum.Font.GothamBold
	btnClearAll.TextSize = 10
	btnClearAll.Parent = selectRow
	Instance.new("UICorner", btnClearAll).CornerRadius = UDim.new(0, 6)

	local dotListHeader = Instance.new("TextLabel")
	dotListHeader.Size = UDim2.new(1, 0, 0, 16)
	dotListHeader.BackgroundTransparency = 1
	dotListHeader.Text = "SELECT DOTS TO EDIT:"
	dotListHeader.TextColor3 = Color3.fromRGB(180, 190, 205)
	dotListHeader.Font = Enum.Font.GothamBold
	dotListHeader.TextSize = 10
	dotListHeader.TextXAlignment = Enum.TextXAlignment.Left
	dotListHeader.LayoutOrder = 4
	dotListHeader.Parent = content

	DotScrollList = Instance.new("ScrollingFrame")
	DotScrollList.Name = "DotScrollList"
	DotScrollList.Size = UDim2.new(1, 0, 0, 95)
	DotScrollList.BackgroundColor3 = Color3.fromRGB(14, 16, 20)
	DotScrollList.BorderSizePixel = 0
	DotScrollList.CanvasSize = UDim2.new(0, 0, 0, 0)
	DotScrollList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	DotScrollList.ScrollBarThickness = 4
	DotScrollList.ScrollBarImageColor3 = Color3.fromRGB(0, 170, 255)
	DotScrollList.LayoutOrder = 5
	DotScrollList.Parent = content
	Instance.new("UICorner", DotScrollList).CornerRadius = UDim.new(0, 6)

	local scrollLayout = Instance.new("UIListLayout")
	scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
	scrollLayout.Padding = UDim.new(0, 3)
	scrollLayout.Parent = DotScrollList

	local scrollPadding = Instance.new("UIPadding")
	scrollPadding.PaddingTop = UDim.new(0, 4)
	scrollPadding.PaddingBottom = UDim.new(0, 4)
	scrollPadding.PaddingLeft = UDim.new(0, 4)
	scrollPadding.PaddingRight = UDim.new(0, 4)
	scrollPadding.Parent = DotScrollList

	local lblInfo = Instance.new("TextLabel")
	lblInfo.Size = UDim2.new(1, 0, 0, 18)
	lblInfo.BackgroundTransparency = 1
	lblInfo.Text = "Total Dots: 0 | Selected: 0"
	lblInfo.TextColor3 = Color3.fromRGB(170, 180, 195)
	lblInfo.Font = Enum.Font.Gotham
	lblInfo.TextSize = 10
	lblInfo.LayoutOrder = 6
	lblInfo.Parent = content

	local function CreateStepper(labelTitle: string, layoutOrder: number): (TextLabel, TextButton, TextButton)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(1, 0, 0, 28)
		frame.BackgroundTransparency = 1
		frame.LayoutOrder = layoutOrder
		frame.Parent = content

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(0.55, 0, 1, 0)
		lbl.BackgroundTransparency = 1
		lbl.Text = labelTitle
		lbl.TextColor3 = Color3.fromRGB(200, 205, 215)
		lbl.Font = Enum.Font.Gotham
		lbl.TextSize = 10
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.Parent = frame

		local btnMinus = Instance.new("TextButton")
		btnMinus.Size = UDim2.new(0.2, -3, 1, 0)
		btnMinus.Position = UDim2.new(0.55, 0, 0, 0)
		btnMinus.BackgroundColor3 = Color3.fromRGB(45, 50, 60)
		btnMinus.Text = "-"
		btnMinus.TextColor3 = Color3.fromRGB(255, 255, 255)
		btnMinus.Font = Enum.Font.GothamBold
		btnMinus.TextSize = 12
		btnMinus.Parent = frame
		Instance.new("UICorner", btnMinus).CornerRadius = UDim.new(0, 6)

		local btnPlus = Instance.new("TextButton")
		btnPlus.Size = UDim2.new(0.2, -3, 1, 0)
		btnPlus.Position = UDim2.new(0.77, 0, 0, 0)
		btnPlus.BackgroundColor3 = Color3.fromRGB(45, 50, 60)
		btnPlus.Text = "+"
		btnPlus.TextColor3 = Color3.fromRGB(255, 255, 255)
		btnPlus.Font = Enum.Font.GothamBold
		btnPlus.TextSize = 12
		btnPlus.Parent = frame
		Instance.new("UICorner", btnPlus).CornerRadius = UDim.new(0, 6)

		return lbl, btnMinus, btnPlus
	end

	local lblSpeed, btnSpeedMinus, btnSpeedPlus = CreateStepper("Speed: 15 stud/s", 7)
	local lblPause, btnPauseMinus, btnPausePlus = CreateStepper("Pause: 1.0s", 8)

	local btnPlay = CreateButton("START CINEMATIC", Color3.fromRGB(40, 150, 80), 9)
	local btnStop = CreateButton("STOP", Color3.fromRGB(180, 60, 60), 10)
	btnStop.Visible = false

	POVOverlay = Instance.new("Frame")
	POVOverlay.Name = "POVOverlay"
	POVOverlay.Size = UDim2.new(1, 0, 1, 0)
	POVOverlay.BackgroundTransparency = 1
	POVOverlay.Visible = false
	POVOverlay.Parent = ScreenGui

	POVTouchArea = Instance.new("Frame")
	POVTouchArea.Name = "POVTouchArea"
	POVTouchArea.Size = UDim2.new(1, 0, 1, 0)
	POVTouchArea.BackgroundTransparency = 1
	POVTouchArea.ZIndex = 1
	POVTouchArea.Parent = POVOverlay

	local btnClosePOV = Instance.new("TextButton")
	btnClosePOV.Name = "BtnClosePOV"
	btnClosePOV.Size = UDim2.new(0, 42, 0, 42)
	btnClosePOV.Position = UDim2.new(0, 15, 0, 15)
	btnClosePOV.BackgroundColor3 = Color3.fromRGB(200, 40, 40)
	btnClosePOV.Text = "✕"
	btnClosePOV.TextColor3 = Color3.fromRGB(255, 255, 255)
	btnClosePOV.Font = Enum.Font.GothamBold
	btnClosePOV.TextSize = 20
	btnClosePOV.ZIndex = 10
	btnClosePOV.Parent = POVOverlay
	Instance.new("UICorner", btnClosePOV).CornerRadius = UDim.new(0, 10)

	local povBanner = Instance.new("TextLabel")
	povBanner.Size = UDim2.new(0, 260, 0, 38)
	povBanner.Position = UDim2.new(0.5, -130, 0.05, 0)
	povBanner.BackgroundColor3 = Color3.fromRGB(15, 18, 22)
	povBanner.BackgroundTransparency = 0.2
	povBanner.Text = "POSITION EDIT MODE\nDrag screen to rotate | Move camera to place dots"
	povBanner.TextColor3 = Color3.fromRGB(255, 200, 0)
	povBanner.Font = Enum.Font.GothamBold
	povBanner.TextSize = 10
	povBanner.ZIndex = 10
	povBanner.Parent = POVOverlay
	Instance.new("UICorner", povBanner).CornerRadius = UDim.new(0, 8)

	local navFrame = Instance.new("Frame")
	navFrame.Size = UDim2.new(0, 150, 0, 150)
	navFrame.Position = UDim2.new(0, 20, 1, -170)
	navFrame.BackgroundTransparency = 1
	navFrame.ZIndex = 10
	navFrame.Parent = POVOverlay

	local function CreateNavButton(name: string, text: string, pos: UDim2, size: UDim2): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.Size = size
		btn.Position = pos
		btn.BackgroundColor3 = Color3.fromRGB(35, 40, 50)
		btn.BackgroundTransparency = 0.3
		btn.Text = text
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 14
		btn.ZIndex = 10
		btn.Parent = navFrame
		Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
		return btn
	end

	local btnFwd = CreateNavButton("Fwd", "▲", UDim2.new(0, 50, 0, 0), UDim2.new(0, 50, 0, 45))
	local btnBack = CreateNavButton("Back", "▼", UDim2.new(0, 50, 0, 100), UDim2.new(0, 50, 0, 45))
	local btnLeft = CreateNavButton("Left", "◄", UDim2.new(0, 0, 0, 50), UDim2.new(0, 45, 0, 45))
	local btnRight = CreateNavButton("Right", "►", UDim2.new(0, 105, 0, 50), UDim2.new(0, 45, 0, 45))

	local vertFrame = Instance.new("Frame")
	vertFrame.Size = UDim2.new(0, 50, 0, 100)
	vertFrame.Position = UDim2.new(1, -70, 1, -145)
	vertFrame.BackgroundTransparency = 1
	vertFrame.ZIndex = 10
	vertFrame.Parent = POVOverlay

	local btnUp = Instance.new("TextButton")
	btnUp.Size = UDim2.new(1, 0, 0, 45)
	btnUp.Position = UDim2.new(0, 0, 0, 0)
	btnUp.BackgroundColor3 = Color3.fromRGB(35, 40, 50)
	btnUp.BackgroundTransparency = 0.3
	btnUp.Text = "UP"
	btnUp.TextColor3 = Color3.fromRGB(255, 255, 255)
	btnUp.Font = Enum.Font.GothamBold
	btnUp.TextSize = 12
	btnUp.ZIndex = 10
	btnUp.Parent = vertFrame
	Instance.new("UICorner", btnUp).CornerRadius = UDim.new(0, 8)

	local btnDown = Instance.new("TextButton")
	btnDown.Size = UDim2.new(1, 0, 0, 45)
	btnDown.Position = UDim2.new(0, 0, 0, 55)
	btnDown.BackgroundColor3 = Color3.fromRGB(35, 40, 50)
	btnDown.BackgroundTransparency = 0.3
	btnDown.Text = "DN"
	btnDown.TextColor3 = Color3.fromRGB(255, 255, 255)
	btnDown.Font = Enum.Font.GothamBold
	btnDown.TextSize = 12
	btnDown.ZIndex = 10
	btnDown.Parent = vertFrame
	Instance.new("UICorner", btnDown).CornerRadius = UDim.new(0, 8)

	local function BindHold(btn: TextButton, moveDir: Vector3)
		btn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				PovMoveVector = PovMoveVector + moveDir
			end
		end)
		btn.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				PovMoveVector = PovMoveVector - moveDir
			end
		end)
	end

	BindHold(btnFwd, Vector3.new(0, 0, -1))
	BindHold(btnBack, Vector3.new(0, 0, 1))
	BindHold(btnLeft, Vector3.new(-1, 0, 0))
	BindHold(btnRight, Vector3.new(1, 0, 0))
	BindHold(btnUp, Vector3.new(0, 1, 0))
	BindHold(btnDown, Vector3.new(0, -1, 0))

	PlaybackOverlay = Instance.new("Frame")
	PlaybackOverlay.Name = "PlaybackOverlay"
	PlaybackOverlay.Size = UDim2.new(1, 0, 1, 0)
	PlaybackOverlay.BackgroundTransparency = 1
	PlaybackOverlay.Visible = false
	PlaybackOverlay.Parent = ScreenGui

	local btnClosePlayback = Instance.new("TextButton")
	btnClosePlayback.Name = "BtnClosePlayback"
	btnClosePlayback.Size = UDim2.new(0, 42, 0, 42)
	btnClosePlayback.Position = UDim2.new(0, 15, 0, 15)
	btnClosePlayback.BackgroundColor3 = Color3.fromRGB(200, 40, 40)
	btnClosePlayback.Text = "✕"
	btnClosePlayback.TextColor3 = Color3.fromRGB(255, 255, 255)
	btnClosePlayback.Font = Enum.Font.GothamBold
	btnClosePlayback.TextSize = 20
	btnClosePlayback.Parent = PlaybackOverlay
	Instance.new("UICorner", btnClosePlayback).CornerRadius = UDim.new(0, 10)

	btnClosePlayback.Activated:Connect(function()
		StopCinematic()
	end)

	local function ToggleDotSelection(index: number)
		if SelectedIndices[index] then
			SelectedIndices[index] = nil
		else
			SelectedIndices[index] = true
		end
	end

	local function UpdateScrollList()
		for _, child in ipairs(DotScrollList:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end

		for i, kf in ipairs(Keyframes) do
			local isSelected = SelectedIndices[i] == true
			local dotBtn = Instance.new("TextButton")
			dotBtn.Name = "DotItem_" .. i
			dotBtn.Size = UDim2.new(1, 0, 0, 24)
			dotBtn.Font = Enum.Font.GothamBold
			dotBtn.TextSize = 10
			
			local checkMark = isSelected and "[✓] " or "[   ] "
			dotBtn.Text = string.format("  %sDot #%d (Spd: %.1f | Pause: %.1fs)", checkMark, i, kf.Speed, kf.StopTime)
			dotBtn.TextXAlignment = Enum.TextXAlignment.Left

			if isSelected then
				dotBtn.BackgroundColor3 = Color3.fromRGB(40, 180, 80)
				dotBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			else
				dotBtn.BackgroundColor3 = Color3.fromRGB(28, 32, 40)
				dotBtn.TextColor3 = Color3.fromRGB(220, 225, 235)
			end

			Instance.new("UICorner", dotBtn).CornerRadius = UDim.new(0, 5)

			local targetIndex = i
			dotBtn.Activated:Connect(function()
				ToggleDotSelection(targetIndex)
				RefreshUI()
			end)

			dotBtn.Parent = DotScrollList
		end
	end

	local function RefreshUI()
		local totalDots = #Keyframes
		local selCount = GetSelectedCount()

		lblInfo.Text = string.format("Total Dots: %d | Selected: %d", totalDots, selCount)

		if selCount > 0 then
			local selList = GetSelectedIndicesList()
			local firstKF = Keyframes[selList[1]]
			lblSpeed.Text = string.format("Speed: %.1f", firstKF.Speed)
			lblPause.Text = string.format("Pause: %.1fs", firstKF.StopTime)
		else
			lblSpeed.Text = string.format("Speed: %.1f (Def)", DefaultSpeed)
			lblPause.Text = string.format("Pause: %.1fs (Def)", DefaultStopTime)
		end

		for i, kf in ipairs(Keyframes) do
			UpdateMarkerAppearance(kf, SelectedIndices[i] == true)
		end

		btnSelectAll.Text = (selCount == totalDots and totalDots > 0) and "DESELECT ALL" or "SELECT ALL"

		btnPlacement.Text = (State == "PLACEMENT") and "PLACEMENT MODE: ON" or "PLACEMENT MODE: OFF"
		btnPlacement.BackgroundColor3 = (State == "PLACEMENT") and Color3.fromRGB(0, 140, 200)
			or Color3.fromRGB(45, 50, 60)

		UpdateScrollList()
	end

	btnSelectAll.Activated:Connect(function()
		local totalDots = #Keyframes
		if totalDots == 0 then return end

		if GetSelectedCount() == totalDots then
			table.clear(SelectedIndices)
		else
			for i = 1, totalDots do
				SelectedIndices[i] = true
			end
		end
		RefreshUI()
	end)

	headerClose.Activated:Connect(function()
		if State == "PLACEMENT" then
			State = "IDLE"
			RefreshUI()
		elseif State == "PLAYBACK" then
			StopCinematic()
		elseif State == "POV_EDIT" then
			ExitPOVMode()
		end
	end)

	btnClosePOV.Activated:Connect(function()
		if State == "POV_EDIT" then
			ExitPOVMode()
		end
	end)

	btnDelete.Activated:Connect(function()
		local selList = GetSelectedIndicesList()
		if #selList == 0 then return end

		for i = #selList, 1, -1 do
			local idx = selList[i]
			local kf = table.remove(Keyframes, idx)
			if kf then
				if kf.MarkerPart then kf.MarkerPart:Destroy() end
				if kf.ArrowPart then kf.ArrowPart:Destroy() end
			end
		end

		table.clear(SelectedIndices)
		RefreshKeyframeIndices()
		RefreshUI()
	end)

	btnClearAll.Activated:Connect(function()
		ClearAllKeyframes()
	end)

	btnPlacement.Activated:Connect(function()
		if State == "PLAYBACK" or State == "POV_EDIT" then
			return
		end
		State = (State == "PLACEMENT") and "IDLE" or "PLACEMENT"
		RefreshUI()
	end)

	btnSpeedMinus.Activated:Connect(function()
		local selList = GetSelectedIndicesList()
		if #selList > 0 then
			for _, idx in ipairs(selList) do
				Keyframes[idx].Speed = math.max(0.5, Keyframes[idx].Speed - 2.5)
			end
		else
			DefaultSpeed = math.max(0.5, DefaultSpeed - 2.5)
		end
		RefreshUI()
	end)

	btnSpeedPlus.Activated:Connect(function()
		local selList = GetSelectedIndicesList()
		if #selList > 0 then
			for _, idx in ipairs(selList) do
				Keyframes[idx].Speed = math.min(500, Keyframes[idx].Speed + 2.5)
			end
		else
			DefaultSpeed = math.min(500, DefaultSpeed + 2.5)
		end
		RefreshUI()
	end)

	btnPauseMinus.Activated:Connect(function()
		local selList = GetSelectedIndicesList()
		if #selList > 0 then
			for _, idx in ipairs(selList) do
				Keyframes[idx].StopTime = math.max(0, Keyframes[idx].StopTime - 0.5)
			end
		else
			DefaultStopTime = math.max(0, DefaultStopTime - 0.5)
		end
		RefreshUI()
	end)

	btnPausePlus.Activated:Connect(function()
		local selList = GetSelectedIndicesList()
		if #selList > 0 then
			for _, idx in ipairs(selList) do
				Keyframes[idx].StopTime = math.min(3600, Keyframes[idx].StopTime + 0.5)
			end
		else
			DefaultStopTime = math.min(3600, DefaultStopTime + 0.5)
		end
		RefreshUI()
	end)

	return {
		RefreshUI = RefreshUI,
		BtnPlay = btnPlay,
		BtnStop = btnStop,
		BtnPOV = btnPOV,
	}
end

local UIControllers = BuildUI()

ClearAllKeyframes = function()
	for _, kf in ipairs(Keyframes) do
		if kf.MarkerPart then kf.MarkerPart:Destroy() end
		if kf.ArrowPart then kf.ArrowPart:Destroy() end
	end
	table.clear(Keyframes)
	table.clear(SelectedIndices)
	ClearPathBeams()
	UIControllers.RefreshUI()
end

--------------------------------------------------------------------------------
-- POV / REAL-TIME GROUP POSITION EDITING CONTROLLER
--------------------------------------------------------------------------------
local function UpdateSelectedDotsCFrame()
	local newPrimaryCF = CurrentCamera.CFrame
	for idx, relCF in pairs(PovRelativeOffsets) do
		if Keyframes[idx] then
			UpdateKeyframeTransform(Keyframes[idx], newPrimaryCF * relCF)
		end
	end
	UpdatePathVisuals()
end

local function EnterPOVMode()
	local selList = GetSelectedIndicesList()
	if #selList == 0 or State == "PLAYBACK" then
		return
	end

	State = "POV_EDIT"
	MainFrame.Visible = false
	POVOverlay.Visible = true

	SetTouchControlsVisible(false)

	PovPrimaryIdx = selList[1]
	local primaryKF = Keyframes[PovPrimaryIdx]

	CurrentCamera.CameraType = Enum.CameraType.Scriptable
	CurrentCamera.CFrame = primaryKF.CFrame

	table.clear(PovRelativeOffsets)
	local primaryCF = primaryKF.CFrame
	for _, idx in ipairs(selList) do
		PovRelativeOffsets[idx] = primaryCF:ToObjectSpace(Keyframes[idx].CFrame)
	end

	local rx, ry, _ = primaryKF.CFrame:ToOrientation()
	PovPitch = rx
	PovYaw = ry
	PovMoveVector = Vector3.zero

	PovRenderConn = RunService.RenderStepped:Connect(function(dt)
		if State ~= "POV_EDIT" then
			return
		end

		if PovMoveVector.Magnitude > 0 then
			local camCFrame = CurrentCamera.CFrame
			local moveSpeed = 16.0 * dt
			
			local worldMove = (camCFrame.RightVector * PovMoveVector.X)
				+ (Vector3.new(0, 1, 0) * PovMoveVector.Y)
				+ (camCFrame.LookVector * (-PovMoveVector.Z))
			
			CurrentCamera.CFrame = camCFrame + (worldMove * moveSpeed)
			UpdateSelectedDotsCFrame()
		end
	end)
end

POVTouchArea.InputChanged:Connect(function(input)
	if State ~= "POV_EDIT" then
		return
	end

	if
		input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseMovement
	then
		local delta = input.Delta
		PovYaw = PovYaw - (delta.X * 0.005)
		PovPitch = math.clamp(PovPitch - (delta.Y * 0.005), math.rad(-85), math.rad(85))

		local currentPos = CurrentCamera.CFrame.Position
		CurrentCamera.CFrame = CFrame.new(currentPos) * CFrame.Angles(0, PovYaw, 0) * CFrame.Angles(PovPitch, 0, 0)
		UpdateSelectedDotsCFrame()
	end
end)

ExitPOVMode = function()
	if State ~= "POV_EDIT" then
		return
	end

	if PovRenderConn then
		PovRenderConn:Disconnect()
		PovRenderConn = nil
	end

	State = "IDLE"
	POVOverlay.Visible = false
	MainFrame.Visible = true

	SetTouchControlsVisible(true)

	CurrentCamera.CameraType = Enum.CameraType.Custom
	UIControllers.RefreshUI()
end

UIControllers.BtnPOV.Activated:Connect(function()
	if State == "POV_EDIT" then
		ExitPOVMode()
	else
		local selList = GetSelectedIndicesList()
		if #selList > 0 then
			EnterPOVMode()
		else
			-- If no dot is selected, set current camera position to all selected or place/align to current camera view
			for i = 1, #Keyframes do
				SelectedIndices[i] = true
			end
			UIControllers.RefreshUI()
			EnterPOVMode()
		end
	end
end)

--------------------------------------------------------------------------------
-- RAYCASTING & TOUCH KEYFRAME CREATION
--------------------------------------------------------------------------------
local function ProcessWorldTap(touchPos: Vector2)
	local ray = CurrentCamera:ViewportPointToRay(touchPos.X, touchPos.Y)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	local ignoreList = { KeyframeFolder }
	if LocalPlayer.Character then
		table.insert(ignoreList, LocalPlayer.Character)
	end
	raycastParams.FilterDescendantsInstances = ignoreList

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 500, raycastParams)
	local targetCFrame: CFrame

	if result then
		local targetPos = result.Position + (result.Normal * 0.5)
		targetCFrame = CFrame.lookAt(targetPos, targetPos + ray.Direction)
	else
		local targetPos = ray.Origin + (ray.Direction * 25)
		targetCFrame = CFrame.lookAt(targetPos, targetPos + ray.Direction)
	end

	local newIndex = #Keyframes + 1
	local kf = CreateVisualMarker(targetCFrame, newIndex)
	table.insert(Keyframes, kf)

	table.clear(SelectedIndices)
	SelectedIndices[newIndex] = true

	RefreshKeyframeIndices()
	UIControllers.RefreshUI()
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if
		input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1
	then
		if State == "PLACEMENT" then
			local tapPos = Vector2.new(input.Position.X, input.Position.Y)
			ProcessWorldTap(tapPos)
		end
	end
end)

--------------------------------------------------------------------------------
-- CINEMATIC PLAYBACK ENGINE
--------------------------------------------------------------------------------
local PlaybackThread: thread? = nil

StopCinematic = function()
	State = "IDLE"

	if PlaybackThread then
		task.cancel(PlaybackThread)
		PlaybackThread = nil
	end

	CurrentCamera.CameraType = SavedCamType
	CurrentCamera.CameraSubject = SavedCamSubject
	CurrentCamera.CFrame = SavedCamCFrame

	SetTouchControlsVisible(true)

	SetVisualsVisible(true)
	MainFrame.Visible = true
	PlaybackOverlay.Visible = false
	UIControllers.BtnStop.Visible = false
	UIControllers.BtnPlay.Visible = true
	UIControllers.RefreshUI()
end

local function StartCinematic()
	if #Keyframes < 1 or State == "PLAYBACK" then
		return
	end

	SavedCamCFrame = CurrentCamera.CFrame
	SavedCamType = CurrentCamera.CameraType
	SavedCamSubject = CurrentCamera.CameraSubject

	State = "PLAYBACK"

	SetTouchControlsVisible(false)

	SetVisualsVisible(false)
	MainFrame.Visible = false
	PlaybackOverlay.Visible = true
	UIControllers.BtnPlay.Visible = false
	UIControllers.BtnStop.Visible = true

	CurrentCamera.CameraType = Enum.CameraType.Scriptable

	PlaybackThread = task.spawn(function()
		CurrentCamera.CFrame = Keyframes[1].CFrame

		for i = 1, #Keyframes - 1 do
			if State ~= "PLAYBACK" then
				break
			end

			local kfStart = Keyframes[i]
			local kfEnd = Keyframes[i + 1]

			local distance = (kfEnd.CFrame.Position - kfStart.CFrame.Position).Magnitude
			local speed = math.max(kfStart.Speed, 0.01)
			local travelDuration = distance / speed

			local elapsed = 0
			while elapsed < travelDuration do
				if State ~= "PLAYBACK" then
					return
				end
				local dt = RunService.RenderStepped:Wait()
				elapsed += dt
				local alpha = math.clamp(elapsed / travelDuration, 0, 1)

				local smoothAlpha = TweenService:GetValue(
					alpha,
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.InOut
				)
				CurrentCamera.CFrame = kfStart.CFrame:Lerp(kfEnd.CFrame, smoothAlpha)
			end

			CurrentCamera.CFrame = kfEnd.CFrame

			if kfEnd.StopTime > 0 then
				local pauseTime = kfEnd.StopTime
				local pauseElapsed = 0
				while pauseElapsed < pauseTime do
					if State ~= "PLAYBACK" then
						return
					end
					local dt = RunService.RenderStepped:Wait()
					pauseElapsed += dt
				end
			end
		end

		StopCinematic()
	end)
end

UIControllers.BtnPlay.Activated:Connect(StartCinematic)
UIControllers.BtnStop.Activated:Connect(StopCinematic)

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------
LocalPlayer.CharacterRemoving:Connect(function()
	SetTouchControlsVisible(true)
	if State == "PLAYBACK" then
		StopCinematic()
	elseif State == "POV_EDIT" then
		ExitPOVMode()
	end
end)
