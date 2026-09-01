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
	btnDow
