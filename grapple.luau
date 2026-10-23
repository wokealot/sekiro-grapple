-- Connected Discord-GitHub
-- GrappleAssets prefabs (hook, emitters) and the Cast anim are from Rudimentality's MIT grapple (2019), anim reuploaded on my account. code is mine

--|| Services ||--
local CollectionService = game:GetService("CollectionService") -- grapple points are tagged, this finds them
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- prefabs live here
local RunService = game:GetService("RunService") -- frame loop for the flight + target scan
local TweenService = game:GetService("TweenService") -- hook travel + fov kick
local UserInputService = game:GetService("UserInputService") -- grapple key
local Workspace = game:GetService("Workspace") -- raycasts + camera

--|| Variables ||--
local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera -- aim is based off where the camera looks, not the character
local Assets = ReplicatedStorage:WaitForChild("GrappleAssets") -- waits for the prefab folder to replicate

local GrappleKey = Enum.KeyCode.E
local PointTag = "GrapplePoint" -- tag on the point parts
local MaxRange = 90 -- furthest you can grapple from, studs
local ShowRange = MaxRange * 2 -- past MaxRange the marker shows faded, past this its ignored completely
local ConeDot = math.cos(math.rad(40)) -- point has to be within 40 degrees of the camera. stored as cos so it compares straight against a dot product, no acos every scan
local ScanInterval = 0.1 -- how often we look for a new target

local CastTime = 0.25 -- windup before the pull starts, hook flies out during this
local FlightSpeed = 75 -- studs per second along the arc
local MinFlight = 0.3 -- shortest a pull can be so close points dont just snap
local ArcHeight = 10 -- how far the middle of the arc gets lifted
local Correction = 8 -- how hard we pull back onto the arc if physics knocks us off
local LandOffset = vector.create(0, 7, 0) -- arc ends this far above the point so you drop down onto it
local ReleaseAt = 0.85 -- let go at 85% of the arc, momentum carries the rest. feels like sekiro instead of sliding to a stop
local StuckDistance = 12 -- this far off the arc means we hit something, cancel
local Cooldown = 0.4
local FovKick = 20 -- how much the fov widens on fire
local MarkerFar = 0.75 -- marker transparency when the point is visible but too far

--|| Cleaner ||--
local Cleaner = {} -- tiny trove. holds connections + instances so Destroy can clear everything in one call
Cleaner.__index = Cleaner

function Cleaner.Add(self : any, Object : any): any
	table.insert(self.Objects, Object)

	return Object -- returns it so you can do X = Cleaner:Add(thing) on one line
end

function Cleaner.Clean(self : any)
	for Index = #self.Objects, 1, -1 do -- backwards so the newest stuff gets cleaned first
		local Object = self.Objects[Index]

		if typeof(Object) == "RBXScriptConnection" then -- typeof knows roblox types, type() would just say userdata
			Object:Disconnect() -- connections get disconnected
		else
			Object:Destroy() -- everything else is an instance
		end

		self.Objects[Index] = nil
	end
end

function Cleaner.new(): any
	return setmetatable({ Objects = {} }, Cleaner) -- links the new table to the methods above
end

--|| Grapple ||--
local Grapple = {} -- one of these per character
Grapple.__index = Grapple

export type Class = any

local function Bezier(A : vector, B : vector, C : vector, T : number): (vector, vector) -- point on a curve from A to C that bends toward B, at progress T
	local Inverse = 1 - T -- 1 at the start, 0 at the end
	local Position = Inverse * Inverse * A + 2 * Inverse * T * B + T * T * C -- quadratic bezier formula
	local Tangent = 2 * Inverse * (B - A) + 2 * T * (C - B) -- derivative of it, which way the curve is heading at this T

	return Position, Tangent
end

function Grapple.GetAimDot(self : Class, Point : BasePart): (number?, boolean) -- checks if a point is a valid target and how centred it is on screen
	if not Point:IsDescendantOf(Workspace) then -- point got deleted since the last scan
		return nil, false
	end

	local Origin = self.RootPart.Position :: vector
	local Offset = Point.Position - Origin -- character to point
	local Distance = vector.magnitude(Offset)

	if Distance > ShowRange then -- too far to even show a marker. cheapest check so it goes first
		return nil, false
	end

	local ToPoint = vector.normalize(Point.Position - Camera.CFrame.Position) -- camera to point, unit length
	local Dot = vector.dot(Camera.CFrame.LookVector :: vector, ToPoint) -- 1 = dead centre of screen, lower = off to the side

	if Dot < ConeDot then -- more than 40 degrees off centre
		return nil, false
	end

	local Hit = Workspace:Raycast(Origin, Offset, self.RayParams) -- ray from character to point, exact length

	if Hit and Hit.Instance ~= Point then -- hit something that isnt the point, so theres a wall in the way
		return nil, false
	end

	return Dot, Distance <= MaxRange -- dot for ranking, bool for can we actually fire
end

function Grapple.FindTarget(self : Class): (BasePart?, boolean) -- picks the best point out of all of them
	local Best, BestDot, BestInRange = nil, ConeDot, false

	for _, Point in CollectionService:GetTagged(PointTag) do -- every tagged instance in the game
		if not Point:IsA("BasePart") then -- tag could be on a folder or something, skip
			continue
		end

		local Dot, InRange = self:GetAimDot(Point)

		if not Dot then -- failed a check
			continue
		end

		local Better = not Best -- first valid point always wins
			or (InRange and not BestInRange) -- in range beats out of range
			or (InRange == BestInRange and Dot > BestDot) -- same range tier, closer to centre wins

		if Better then
			Best, BestDot, BestInRange = Point, Dot, InRange
		end
	end

	return Best, BestInRange
end

function Grapple.SetTarget(self : Class, Point : BasePart?, InRange : boolean) -- stores the target and updates the marker
	if self.Target == Point and self.InRange == InRange then -- nothing changed
		return
	end

	self.Target = Point
	self.InRange = InRange
	self.Indicator.Adornee = Point -- billboard draws on whatever its adornee is
	self.Indicator.Enabled = Point ~= nil -- hide when theres no target
	self.Indicator.Frame.BackgroundTransparency = if InRange then 0.25 else MarkerFar -- solid in range, faded out of range
end

function Grapple.CanFire(self : Class): boolean
	if self.Destroyed or self.Flight or not self.InRange then -- destroyed, already flying, or target too far
		return false
	end

	if self.Humanoid.Health <= 0 then
		return false
	end

	return os.clock() - self.LastFiredAt >= Cooldown -- os.clock cuz it doesnt jump with the system clock
end

function Grapple.PlayEffects(self : Class, Point : BasePart) -- everything visual when the grapple fires
	local Hook = Assets.Hook:Clone() -- prefab ball with a Beam inside, Attachment1 already set to its own attachment
	local Hand = self.Character:FindFirstChild("RightHand")
	local Grip = (Hand and Hand:FindFirstChild("RightGripAttachment")) or self.RootPart.RootAttachment -- r15 palm attachment, falls back to the root one every rig has

	Hook.Beam.Attachment0 = Grip -- beam goes hand -> hook
	Hook.CFrame = Grip.WorldCFrame -- start in the hand
	Hook.Parent = self.Character

	TweenService:Create(Hook, TweenInfo.new(CastTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = CFrame.new(Point.Position) }):Play() -- hook flies to the point during the windup. dies with the hook so no need to track it

	self.BaseFov = Camera.FieldOfView -- saved so Arrive can put it back exactly, otherwise fast double fires stack the kick
	self.FovTween = TweenService:Create(Camera, TweenInfo.new(CastTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, true), { FieldOfView = self.BaseFov + FovKick }) -- reverses = true so it tweens back on its own
	self.FovTween:Play()

	self.RootEmitter.Enabled = true -- smoke trail on

	if self.CastTrack then
		self.CastTrack:Play(0.1, 1, if self.CastTrack.Length > 0 then self.CastTrack.Length / (CastTime * 2) else 1) -- fade, weight, speed. speed scaled so the anim fits the windup. Length is 0 until the anim loads so fall back to 1
	end

	self.Hook = Hook -- kept so Arrive can remove it
end

function Grapple.Fire(self : Class) -- starts a grapple to the current target
	if not self:CanFire() then
		return
	end

	local Point = self.Target :: BasePart
	local _, StillInRange = self:GetAimDot(Point) -- recheck cuz the target can move or get blocked between scans

	if not StillInRange then
		self:SetTarget(nil, false)
		return
	end

	local Root = self.RootPart :: BasePart

	self.LastFiredAt = os.clock() -- start the cooldown
	self:PlayEffects(Point)

	local Start = Root.Position :: vector
	local Finish = Point.Position + LandOffset -- above the point
	local Distance = vector.magnitude(Finish - Start)
	local Control = (Start + Finish) / 2 + vector.create(0, ArcHeight, 0) -- midpoint lifted up, thats what bends it into an arc

	self.Flight = { -- everything Update needs
		Point = Point,
		Start = Start,
		Control = Control,
		Finish = Finish,
		Duration = math.max(Distance / FlightSpeed, MinFlight), -- further = longer, with a floor
		Elapsed = -CastTime, -- starts negative so the windup counts down first, pull begins at 0
	}

	self.Humanoid:ChangeState(Enum.HumanoidStateType.Physics) -- physics state so the humanoid stops applying its own walk/balance forces and fights our velocity
end

function Grapple.Arrive(self : Class, Succeeded : boolean) -- ends the flight and cleans the effects
	local Flight = self.Flight

	if not Flight then
		return
	end

	self.Flight = nil

	if Succeeded and Flight.Point:IsDescendantOf(Workspace) then -- only play the impact if we actually got there and the point still exists
		local Effect = Assets.Impact:Clone() -- invisible part with the dust + spark emitters
		Effect.CFrame = Flight.Point.CFrame
		Effect.Parent = Workspace
		Effect.DustEmitter:Emit(2) -- Emit works with the emitter disabled
		Effect.SparkEmitter:Emit(20)
		task.delay(math.max(Effect.DustEmitter.Lifetime.Max, Effect.SparkEmitter.Lifetime.Max) + 0.1, Effect.Destroy, Effect) -- destroy after the longest particle is gone. Effect gets passed as self
	end

	if self.Hook then
		self.Hook:Destroy() -- takes the beam and the tween with it
		self.Hook = nil
	end

	if self.FovTween then
		self.FovTween:Cancel() -- could still be mid kick if we got cancelled early
		self.FovTween = nil
		Camera.FieldOfView = self.BaseFov -- put it back exactly
	end

	self.RootEmitter.Enabled = false

	if self.Humanoid.Health > 0 then -- dont force a dead character into GettingUp
		self.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) -- out of physics state, humanoid takes over and lands itself
	end
end

function Grapple.Update(self : Class, DeltaTime : number) -- runs every frame, moves the character along the arc
	local Flight = self.Flight

	if not Flight then
		return
	end

	if not Flight.Point:IsDescendantOf(Workspace) then -- point got deleted mid flight
		self:Arrive(false)
		return
	end

	Flight.Elapsed += DeltaTime

	local Root = self.RootPart :: BasePart
	local T = math.clamp(Flight.Elapsed / Flight.Duration, 0, 1) -- 0 to 1 along the arc. clamped so it sits at 0 while Elapsed is still negative in the windup
	local Position, Tangent = Bezier(Flight.Start, Flight.Control, Flight.Finish, T) -- where we should be and which way we're heading

	local Flat = vector.create(Tangent.x, 0, Tangent.z) -- drop the Y so the rig only turns, doesnt tilt

	if vector.magnitude(Flat) > 0.01 then -- straight up has no flat part, lookAt would get a zero vector
		Root.CFrame = CFrame.lookAt(Root.Position, Root.Position + Flat) -- face where we're going
	end

	if Flight.Elapsed < 0 then -- still in the windup
		Root.AssemblyLinearVelocity = vector.zero -- zero it every frame so gravity doesnt drop us while we wait
		return
	end

	local Error = Position - Root.Position -- how far physics pushed us off the arc

	if vector.magnitude(Error) > StuckDistance then -- stuck on something, bail instead of hanging there
		self:Arrive(false)
		return
	end

	Root.AssemblyLinearVelocity = Tangent / Flight.Duration + Error * Correction -- tangent / duration = studs per second along the arc. error * correction pulls us back onto it

	if T >= ReleaseAt then -- 85% there, let go. the velocity we just set carries us over the point and gravity drops us on
		self:Arrive(true)
	end
end

function Grapple.Scan(self : Class, DeltaTime : number) -- runs every frame, repicks the target every 0.1s
	self.ScanClock += DeltaTime

	if self.ScanClock < ScanInterval or self.Flight then -- not time yet, or mid flight
		return
	end

	self.ScanClock %= ScanInterval -- keep the leftover so scans stay evenly spaced
	self:SetTarget(self:FindTarget()) -- FindTarget returns Point, InRange and both go straight in
end

function Grapple.Destroy(self : Class) -- teardown on death / respawn
	if self.Destroyed then
		return
	end

	self.Destroyed = true

	self:Arrive(false) -- ends the flight if theres one, that already clears the hook / fov / smoke
	self.Cleaner:Clean() -- disconnects every event, destroys every instance we made
end

function Grapple.new(Character : Model): Class
	local self = setmetatable({}, Grapple) :: any

	self.Cleaner = Cleaner.new()
	self.Destroyed = false

	self.Character = Character
	self.Humanoid = Character:WaitForChild("Humanoid")
	self.RootPart = Character:WaitForChild("HumanoidRootPart")

	self.Target = nil -- current point
	self.InRange = false -- is the current point close enough to fire at
	self.Flight = nil -- flight data while flying, nil otherwise
	self.Hook = nil -- hook part while its out
	self.FovTween = nil -- fov tween while its running
	self.BaseFov = nil -- fov before the kick
	self.LastFiredAt = 0
	self.ScanClock = 0

	self.RayParams = RaycastParams.new() -- made once per character, reused for every ray
	self.RayParams.FilterType = Enum.RaycastFilterType.Exclude
	self.RayParams.FilterDescendantsInstances = { Character } -- dont let our own limbs block the ray

	local Animator = self.Humanoid:WaitForChild("Animator") -- Humanoid:LoadAnimation is deprecated, Animator does it now
	self.CastTrack = if script:FindFirstChild("Cast") then Animator:LoadAnimation(script.Cast) else nil -- anim sits under the script, optional

	self.RootEmitter = self.Cleaner:Add(Assets.RootEmitter:Clone()) -- smoke trail
	self.RootEmitter.Enabled = false
	self.RootEmitter.Parent = self.RootPart -- on the root so it follows the character

	self.Indicator = self.Cleaner:Add(Assets.Indicator:Clone()) -- target marker billboard
	self.Indicator.Enabled = false
	self.Indicator.Parent = LocalPlayer:WaitForChild("PlayerGui") -- in PlayerGui not inside the point, so it survives if the point gets destroyed

	self.Cleaner:Add(UserInputService.InputBegan:Connect(function(Input : InputObject, Processed : boolean)
		if Input.KeyCode ~= GrappleKey or Processed then -- wrong key, or chat/textbox ate it
			return
		end

		self:Fire()
	end))

	self.Cleaner:Add(RunService.PreSimulation:Connect(function(DeltaTime : number) -- before physics each frame, so the velocity we set is what gets simulated
		self:Update(DeltaTime)
		self:Scan(DeltaTime)
	end))

	self.Cleaner:Add(self.Humanoid.Died:Once(function() -- Once disconnects itself after
		self:Destroy()
	end))

	return self
end

--|| Functions ||--
local Current : Class? = nil -- the live grapple object
local SpawnId = 0 -- bumps every spawn, used to catch a respawn that happens while new() is yielding

local function OnCharacterAdded(Character : Model)
	SpawnId += 1
	local ThisSpawn = SpawnId

	if Current then
		Current:Destroy() -- clean up the old character's one first
		Current = nil
	end

	local Controller = Grapple.new(Character) -- yields on WaitForChild, a newer character can spawn during this

	if ThisSpawn ~= SpawnId or LocalPlayer.Character ~= Character then -- a newer spawn happened, this one is stale
		Controller:Destroy()
		return
	end

	Current = Controller
end

LocalPlayer.CharacterAdded:Connect(OnCharacterAdded)

if LocalPlayer.Character then -- character can already exist before this script runs, CharacterAdded already fired
	OnCharacterAdded(LocalPlayer.Character)
end
