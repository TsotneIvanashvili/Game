-- Class catalog: properties (with engine defaults), methods and events for every Roblox class
-- the game touches. Reading or writing a member that is not listed errors like the engine,
-- so a missing entry here shows up as a test failure: add the member (with its real default)
-- rather than loosening the check.

return function(M)
	local T = M.types
	local Enum = M.Enum
	local N, RO, ANY, COMPUTED = M.N, M.RO, M.ANY, M.COMPUTED
	local class = M.class
	local raw, store = M.raw, M.store
	local v3 = M.v3
	local V0 = v3(0, 0, 0)
	local ID = T.CFrame.identity
	local fmt = string.format

	local function c3(r, g, b)
		return T.Color3.fromRGB(r, g, b)
	end
	local function noop() end
	local function stub(ret)
		return function()
			return ret
		end
	end

	-- PVInstance / BasePart -------------------------------------------------------------------
	class("PVInstance", "Instance", {
		abstract = true,
		methods = {
			GetPivot = function(self)
				return M.getPivot(self)
			end,
			PivotTo = function(self, target)
				if M.typeof(target) ~= "CFrame" then
					error("invalid argument #1 to 'PivotTo' (CFrame expected, got " .. M.typeof(target) .. ")", 2)
				end
				M.pivotTo(self, target)
			end,
		},
	})

	local function partCFrameSet(self, v)
		store(self, "CFrame", v)
		M.changed(self, "Position", nil)
		M.changed(self, "Orientation", nil)
		M.partMoved(self)
	end
	local function deg(x)
		return math.deg(x)
	end

	class("BasePart", "PVInstance", {
		abstract = true,
		props = {
			CFrame = { __spec = true, default = ID, type = "CFrame", set = partCFrameSet },
			Position = COMPUTED(function(self)
				return raw(self, "CFrame").Position
			end, function(self, v)
				partCFrameSet(self, raw(self, "CFrame").Rotation + v)
			end, "Vector3"),
			Orientation = COMPUTED(function(self)
				local x, y, z = raw(self, "CFrame"):ToOrientation()
				return v3(deg(x), deg(y), deg(z))
			end, function(self, v)
				local p = raw(self, "CFrame").Position
				partCFrameSet(
					self,
					T.CFrame.new(p) * T.CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
				)
			end, "Vector3"),
			Rotation = COMPUTED(function(self)
				local x, y, z = raw(self, "CFrame"):ToEulerAnglesXYZ()
				return v3(deg(x), deg(y), deg(z))
			end, function(self, v)
				local p = raw(self, "CFrame").Position
				partCFrameSet(self, T.CFrame.new(p) * T.CFrame.Angles(math.rad(v.X), math.rad(v.Y), math.rad(v.Z)))
			end, "Vector3"),
			Size = {
				__spec = true,
				default = v3(4, 1, 2),
				type = "Vector3",
				set = function(self, v)
					v = v3(math.max(v.X, 0.001), math.max(v.Y, 0.001), math.max(v.Z, 0.001))
					if self._cls.isa.Part and raw(self, "Shape") == Enum.PartType.Ball then
						local m = math.min(v.X, v.Y, v.Z)
						v = v3(m, m, m)
					end
					store(self, "Size", v)
					M.partMoved(self)
				end,
			},
			Anchored = false,
			CanCollide = true,
			CanQuery = true,
			CanTouch = true,
			CastShadow = true,
			Transparency = 0,
			LocalTransparencyModifier = 0,
			Reflectance = 0,
			Color = c3(163, 162, 165),
			BrickColor = COMPUTED(function(self)
				return T.BrickColor.new(raw(self, "Color"))
			end, function(self, v)
				store(self, "Color", v.Color)
			end, "BrickColor"),
			Material = Enum.Material.Plastic,
			MaterialVariant = "",
			Massless = false,
			Locked = false,
			AssemblyLinearVelocity = V0,
			AssemblyAngularVelocity = V0,
			Velocity = V0,
			RotVelocity = V0,
			CollisionGroup = "Default",
			CollisionGroupId = 0,
			CustomPhysicalProperties = N("PhysicalProperties"),
			PivotOffset = ID,
			RootPriority = 0,
			EnableFluidForces = true,
			TopSurface = Enum.SurfaceType.Smooth,
			BottomSurface = Enum.SurfaceType.Smooth,
			FrontSurface = Enum.SurfaceType.Smooth,
			BackSurface = Enum.SurfaceType.Smooth,
			LeftSurface = Enum.SurfaceType.Smooth,
			RightSurface = Enum.SurfaceType.Smooth,
			Mass = COMPUTED(function(self)
				return M.partMass(self)
			end),
			AssemblyMass = COMPUTED(function(self)
				return M.partMass(self)
			end),
			AssemblyRootPart = COMPUTED(function(self)
				return self
			end),
			ExtentsSize = COMPUTED(function(self)
				return raw(self, "Size")
			end),
			ResizeIncrement = RO(1),
		},
		methods = {
			SetNetworkOwner = function(self, player)
				if player ~= nil and not (M.isInstance(player) and player._cls.name == "Player") then
					error("invalid argument #1 to 'SetNetworkOwner' (Player expected)", 2)
				end
				if raw(self, "Anchored") then
					error(
						"Network Ownership API cannot be called on Anchored parts or parts welded to Anchored parts.",
						2
					)
				end
				if not self:IsDescendantOf(M.workspace) then
					error("Can only call Network Ownership API on a part that is descendant of Workspace", 2)
				end
				rawset(self, "_netOwner", player or false)
			end,
			GetNetworkOwner = function(self)
				local o = rawget(self, "_netOwner")
				return if o then o else nil
			end,
			SetNetworkOwnershipAuto = function(self)
				if raw(self, "Anchored") then
					error(
						"Network Ownership API cannot be called on Anchored parts or parts welded to Anchored parts.",
						2
					)
				end
				rawset(self, "_netOwner", nil)
			end,
			CanSetNetworkOwnership = function(self)
				if raw(self, "Anchored") then
					return false, "Cannot change network ownership of anchored parts"
				end
				return true
			end,
			GetMass = function(self)
				return M.partMass(self)
			end,
			GetConnectedParts = function(self)
				return { self }
			end,
			GetJoints = stub({}),
			GetTouchingParts = stub({}),
			GetRootPart = function(self)
				return self
			end,
			ApplyImpulse = function(self, impulse)
				if M.typeof(impulse) ~= "Vector3" then
					error("invalid argument #1 to 'ApplyImpulse' (Vector3 expected)", 2)
				end
				local mass = math.max(M.partMass(self), 1e-3)
				M.storeShared(self, "AssemblyLinearVelocity", raw(self, "AssemblyLinearVelocity") + impulse / mass)
			end,
			ApplyAngularImpulse = noop,
			ApplyImpulseAtPosition = noop,
			BreakJoints = noop,
			GetVelocityAtPosition = function(self)
				return raw(self, "AssemblyLinearVelocity")
			end,
		},
		events = { "Touched", "TouchEnded" },
	})
	class("Part", "BasePart", {
		props = {
			Shape = {
				__spec = true,
				default = Enum.PartType.Block,
				type = "EnumItem",
				enum = Enum.PartType,
				set = function(self, v)
					store(self, "Shape", v)
					if v == Enum.PartType.Ball then
						local s = raw(self, "Size")
						local m = math.min(s.X, s.Y, s.Z)
						store(self, "Size", v3(m, m, m))
						M.partMoved(self)
					end
				end,
			},
		},
	})
	class("WedgePart", "BasePart", {})
	class("CornerWedgePart", "BasePart", {})
	class("TrussPart", "BasePart", { props = { Style = Enum.Style.AlternatingSupports } })
	class("SpawnLocation", "Part", {
		props = {
			Neutral = true,
			Duration = 10,
			Enabled = true,
			TeamColor = T.BrickColor.new("Medium stone grey"),
			AllowTeamChangeOnTouch = false,
		},
	})
	class("MeshPart", "BasePart", {
		props = {
			MeshId = "",
			TextureID = "",
			DoubleSided = false,
			RenderFidelity = ANY(nil),
			CollisionFidelity = ANY(nil),
			MeshSize = RO(v3(1, 1, 1)),
		},
	})
	class("UnionOperation", "BasePart", { props = { UsePartColor = false } })
	class("Seat", "Part", {
		props = { Disabled = false, Occupant = COMPUTED(function()
			return nil
		end) },
		methods = { Sit = noop },
	})
	class("VehicleSeat", "BasePart", { props = { Disabled = false, MaxSpeed = 25, Torque = 10, TurnSpeed = 1 } })

	-- Terrain: records operations; surface queries go through an injected height function.
	class("Terrain", "BasePart", {
		notCreatable = true,
		props = {
			WaterColor = c3(12, 84, 92),
			WaterTransparency = 0.3,
			WaterWaveSize = 0.15,
			WaterWaveSpeed = 10,
			WaterReflectance = 1,
			Decoration = false,
			MaxExtents = ANY(nil),
		},
		methods = {
			FillBlock = function(self, frame, size, material)
				if M.typeof(frame) ~= "CFrame" or M.typeof(size) ~= "Vector3" or M.typeof(material) ~= "EnumItem" then
					error("invalid arguments to 'FillBlock' (CFrame, Vector3, Material expected)", 2)
				end
				M.terrainOp(self, "FillBlock", frame, size, material)
			end,
			FillBall = function(self, center, radius, material)
				if M.typeof(center) ~= "Vector3" or type(radius) ~= "number" or M.typeof(material) ~= "EnumItem" then
					error("invalid arguments to 'FillBall' (Vector3, number, Material expected)", 2)
				end
				M.terrainOp(self, "FillBall", center, radius, material)
			end,
			FillCylinder = function(self, frame, height, radius, material)
				if
					M.typeof(frame) ~= "CFrame"
					or type(height) ~= "number"
					or type(radius) ~= "number"
					or M.typeof(material) ~= "EnumItem"
				then
					error("invalid arguments to 'FillCylinder' (CFrame, number, number, Material expected)", 2)
				end
				M.terrainOp(self, "FillCylinder", frame, height, radius, material)
			end,
			FillWedge = function(self, frame, size, material)
				if M.typeof(frame) ~= "CFrame" or M.typeof(size) ~= "Vector3" or M.typeof(material) ~= "EnumItem" then
					error("invalid arguments to 'FillWedge' (CFrame, Vector3, Material expected)", 2)
				end
				M.terrainOp(self, "FillWedge", frame, size, material)
			end,
			FillRegion = function(self, region, resolution, material)
				if
					M.typeof(region) ~= "Region3"
					or type(resolution) ~= "number"
					or M.typeof(material) ~= "EnumItem"
				then
					error("invalid arguments to 'FillRegion'", 2)
				end
				M.terrainOp(self, "FillRegion", region, resolution, material)
			end,
			ReplaceMaterial = function(self, region, resolution, source, target)
				if M.typeof(region) ~= "Region3" then
					error(
						"invalid argument #1 to 'ReplaceMaterial' (Region3 expected, got " .. M.typeof(region) .. ")",
						2
					)
				end
				if resolution ~= 4 then
					error("ReplaceMaterial: resolution must be 4", 2)
				end
				if M.typeof(source) ~= "EnumItem" or M.typeof(target) ~= "EnumItem" then
					error("invalid arguments to 'ReplaceMaterial' (Material expected)", 2)
				end
				M.terrainOp(self, "ReplaceMaterial", region, resolution, source, target)
			end,
			SetMaterialColor = function(self, material, color)
				if M.typeof(material) ~= "EnumItem" or M.typeof(color) ~= "Color3" then
					error("invalid arguments to 'SetMaterialColor' (Material, Color3 expected)", 2)
				end
				rawset(self, "_matColors", rawget(self, "_matColors") or {})
				rawget(self, "_matColors")[material] = color
			end,
			GetMaterialColor = function(self, material)
				local colors = rawget(self, "_matColors")
				return colors and colors[material] or c3(128, 128, 128)
			end,
			Clear = function(self)
				M.terrainOp(self, "Clear")
			end,
			ReadVoxels = function()
				error("mock: Terrain:ReadVoxels is not emulated", 2)
			end,
			WriteVoxels = function(self)
				M.terrainOp(self, "WriteVoxels")
			end,
			CellCenterToWorld = function(_, x, y, z)
				return v3(x * 4 + 2, y * 4 + 2, z * 4 + 2)
			end,
			WorldToCell = function(_, p)
				return v3(math.floor(p.X / 4), math.floor(p.Y / 4), math.floor(p.Z / 4))
			end,
		},
	})

	-- Models / folders -----------------------------------------------------------------------
	class("Model", "PVInstance", {
		props = {
			PrimaryPart = N("Instance", "BasePart"),
			WorldPivot = COMPUTED(function(self)
				return M.getPivot(self)
			end, function(self, v)
				self._p.WorldPivot = v
			end, "CFrame"),
			LevelOfDetail = Enum.ModelLevelOfDetail.Automatic,
			ModelStreamingMode = Enum.ModelStreamingMode.Default,
		},
		methods = {
			GetBoundingBox = function(self)
				return M.boundingBox(self)
			end,
			GetExtentsSize = function(self)
				local _, size = M.boundingBox(self)
				return size
			end,
			MoveTo = function(self, pos)
				local pivot = M.getPivot(self)
				M.pivotTo(self, pivot.Rotation + pos)
			end,
			TranslateBy = function(self, delta)
				M.pivotTo(self, M.getPivot(self) + delta)
			end,
			SetPrimaryPartCFrame = function(self, target)
				local pp = raw(self, "PrimaryPart")
				if not pp then
					error(
						"Model:SetPrimaryPartCFrame() failed because no PrimaryPart has been set, or the PrimaryPart no longer exists.",
						2
					)
				end
				M.pivotTo(self, target * raw(pp, "PivotOffset"))
			end,
			GetPrimaryPartCFrame = function(self)
				local pp = raw(self, "PrimaryPart")
				if not pp then
					error("Model:GetPrimaryPartCFrame() failed because no PrimaryPart has been set", 2)
				end
				return raw(pp, "CFrame")
			end,
			GetScale = stub(1),
			ScaleTo = noop,
			BreakJoints = noop,
			MakeJoints = noop,
		},
	})
	class("Folder", "Instance", {})
	class("Configuration", "Instance", {})
	class("Actor", "Model", {})
	class("WorldModel", "Model", {})

	-- Attachments / constraints --------------------------------------------------------------
	local function attachmentParentCF(self)
		local parent = rawget(self, "_parent")
		if parent and parent._cls.isa.BasePart and not parent._cls.isa.Terrain then
			return raw(parent, "CFrame")
		end
		return ID
	end
	class("Attachment", "Instance", {
		props = {
			CFrame = ID,
			Position = COMPUTED(function(self)
				return raw(self, "CFrame").Position
			end, function(self, v)
				store(self, "CFrame", raw(self, "CFrame").Rotation + v)
			end, "Vector3"),
			Orientation = COMPUTED(function(self)
				local x, y, z = raw(self, "CFrame"):ToOrientation()
				return v3(deg(x), deg(y), deg(z))
			end, function(self, v)
				store(
					self,
					"CFrame",
					T.CFrame.new(raw(self, "CFrame").Position)
						* T.CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
				)
			end, "Vector3"),
			Axis = COMPUTED(function(self)
				return raw(self, "CFrame").RightVector
			end, function(self, v)
				local c = raw(self, "CFrame")
				local up = c.UpVector
				store(self, "CFrame", T.CFrame.fromMatrix(c.Position, v.Unit, up))
			end, "Vector3"),
			SecondaryAxis = COMPUTED(function(self)
				return raw(self, "CFrame").UpVector
			end, function(self, v)
				local c = raw(self, "CFrame")
				store(self, "CFrame", T.CFrame.fromMatrix(c.Position, c.RightVector, v.Unit))
			end, "Vector3"),
			WorldCFrame = COMPUTED(function(self)
				return attachmentParentCF(self) * raw(self, "CFrame")
			end, function(self, v)
				store(self, "CFrame", attachmentParentCF(self):Inverse() * v)
			end, "CFrame"),
			WorldPosition = COMPUTED(function(self)
				return attachmentParentCF(self) * raw(self, "CFrame").Position
			end, function(self, v)
				local rot = raw(self, "CFrame").Rotation
				store(self, "CFrame", rot + attachmentParentCF(self):PointToObjectSpace(v))
			end, "Vector3"),
			WorldOrientation = COMPUTED(function(self)
				local x, y, z = (attachmentParentCF(self) * raw(self, "CFrame")):ToOrientation()
				return v3(deg(x), deg(y), deg(z))
			end),
			WorldAxis = COMPUTED(function(self)
				return (attachmentParentCF(self) * raw(self, "CFrame")).RightVector
			end),
			WorldSecondaryAxis = COMPUTED(function(self)
				return (attachmentParentCF(self) * raw(self, "CFrame")).UpVector
			end),
			Visible = false,
		},
	})
	class("Bone", "Attachment", { props = { Transform = ID } })

	class("Constraint", "Instance", {
		abstract = true,
		props = {
			Enabled = true,
			Attachment0 = N("Instance", "Attachment"),
			Attachment1 = N("Instance", "Attachment"),
			Visible = false,
			Color = T.BrickColor.new("Bright blue"),
			Active = RO(false),
		},
	})
	class("AlignPosition", "Constraint", {
		props = {
			Mode = Enum.PositionAlignmentMode.TwoAttachment,
			Position = V0,
			MaxForce = 10000,
			MaxAxesForce = v3(10000, 10000, 10000),
			MaxVelocity = math.huge,
			Responsiveness = 10,
			RigidityEnabled = false,
			ApplyAtCenterOfMass = false,
			ReactionForceEnabled = false,
			ForceLimitMode = Enum.ForceLimitMode.Magnitude,
			ForceRelativeTo = Enum.ActuatorRelativeTo.World,
		},
	})
	class("AlignOrientation", "Constraint", {
		props = {
			Mode = Enum.OrientationAlignmentMode.TwoAttachment,
			CFrame = ID,
			PrimaryAxis = v3(1, 0, 0),
			SecondaryAxis = v3(0, 1, 0),
			LookAtPosition = V0,
			MaxTorque = 10000,
			MaxAngularVelocity = math.huge,
			Responsiveness = 10,
			RigidityEnabled = false,
			PrimaryAxisOnly = false,
			ReactionTorqueEnabled = false,
			AlignType = Enum.AlignType.AllAxes,
		},
	})
	class("RopeConstraint", "Constraint", {
		props = {
			Length = 5,
			Thickness = 0.1,
			Restitution = 0,
			WinchEnabled = false,
			WinchForce = 10000,
			WinchSpeed = 2,
			WinchTarget = 5,
			WinchResponsiveness = 45,
			CurrentDistance = RO(0),
		},
	})
	class("RodConstraint", "Constraint", {
		props = {
			Length = 5,
			Thickness = 0.1,
			LimitsEnabled = false,
			LimitAngle0 = 90,
			LimitAngle1 = 90,
			CurrentDistance = RO(0),
		},
	})
	class("SpringConstraint", "Constraint", {
		props = {
			Coils = 3,
			Damping = 0,
			FreeLength = 1,
			LimitsEnabled = false,
			MaxForce = math.huge,
			MaxLength = 5,
			MinLength = 0,
			Radius = 0.4,
			Stiffness = 0,
			Thickness = 0.1,
			CurrentLength = RO(0),
		},
	})
	class("BallSocketConstraint", "Constraint", {
		props = {
			LimitsEnabled = false,
			UpperAngle = 45,
			TwistLimitsEnabled = false,
			TwistLowerAngle = -45,
			TwistUpperAngle = 45,
			Restitution = 0,
			MaxFrictionTorque = 0,
			Radius = 0.15,
		},
	})
	class("HingeConstraint", "Constraint", {
		props = {
			ActuatorType = ANY(nil),
			LimitsEnabled = false,
			LowerAngle = -45,
			UpperAngle = 45,
			AngularVelocity = 0,
			AngularSpeed = 0,
			MotorMaxTorque = 0,
			ServoMaxTorque = 0,
			TargetAngle = 0,
			Restitution = 0,
			CurrentAngle = RO(0),
		},
	})
	class("PrismaticConstraint", "Constraint", {
		props = {
			ActuatorType = ANY(nil),
			LimitsEnabled = false,
			LowerLimit = 0,
			UpperLimit = 5,
			Velocity = 0,
			Speed = 0,
			TargetPosition = 0,
			ServoMaxForce = 0,
			MotorMaxForce = 0,
		},
	})
	class("LinearVelocity", "Constraint", {
		props = {
			VectorVelocity = V0,
			MaxForce = 1000,
			VelocityConstraintMode = Enum.VelocityConstraintMode.Vector,
			RelativeTo = Enum.ActuatorRelativeTo.World,
			LineDirection = v3(1, 0, 0),
			LineVelocity = 0,
			PlaneVelocity = T.Vector2.zero,
			ForceLimitsEnabled = true,
			ForceLimitMode = Enum.ForceLimitMode.Magnitude,
		},
	})
	class("AngularVelocity", "Constraint", {
		props = {
			AngularVelocity = V0,
			MaxTorque = 0,
			RelativeTo = Enum.ActuatorRelativeTo.World,
			ReactionTorqueEnabled = false,
		},
	})
	class(
		"VectorForce",
		"Constraint",
		{ props = { Force = V0, RelativeTo = Enum.ActuatorRelativeTo.Attachment0, ApplyAtCenterOfMass = false } }
	)
	class("Torque", "Constraint", { props = { Torque = V0, RelativeTo = Enum.ActuatorRelativeTo.Attachment0 } })
	class(
		"NoCollisionConstraint",
		"Instance",
		{ props = { Enabled = true, Part0 = N("Instance", "BasePart"), Part1 = N("Instance", "BasePart") } }
	)

	class("JointInstance", "Instance", {
		abstract = true,
		props = {
			Part0 = N("Instance", "BasePart"),
			Part1 = N("Instance", "BasePart"),
			C0 = ID,
			C1 = ID,
			Enabled = true,
			Active = COMPUTED(function(self)
				return raw(self, "Enabled") and raw(self, "Part0") ~= nil and raw(self, "Part1") ~= nil
			end),
		},
	})
	class("Weld", "JointInstance", {})
	class("ManualWeld", "JointInstance", {})
	class("Snap", "JointInstance", {})
	class(
		"Motor6D",
		"JointInstance",
		{ props = { Transform = ID, CurrentAngle = 0, DesiredAngle = 0, MaxVelocity = 0 } }
	)
	class("Motor", "JointInstance", { props = { CurrentAngle = 0, DesiredAngle = 0, MaxVelocity = 0 } })
	class("WeldConstraint", "Instance", {
		props = {
			Part0 = N("Instance", "BasePart"),
			Part1 = N("Instance", "BasePart"),
			Enabled = true,
			Active = COMPUTED(function(self)
				return raw(self, "Enabled") and raw(self, "Part0") ~= nil and raw(self, "Part1") ~= nil
			end),
		},
	})

	-- Humanoid --------------------------------------------------------------------------------
	local function humanoidHealthSet(self, v)
		local maxHealth = raw(self, "MaxHealth")
		v = math.clamp(v, 0, maxHealth)
		local old = raw(self, "Health")
		if rawget(self, "_dead") then
			store(self, "Health", math.min(v, 0))
			return
		end
		store(self, "Health", v)
		if v ~= old then
			M.fire(M.getEvent(self, "HealthChanged"), v)
		end
		if v <= 0 and not rawget(self, "_dead") then
			M.humanoidDied(self)
		end
	end
	class("Humanoid", "Instance", {
		props = {
			Health = { __spec = true, default = 100, type = "number", set = humanoidHealthSet },
			MaxHealth = {
				__spec = true,
				default = 100,
				type = "number",
				set = function(self, v)
					store(self, "MaxHealth", v)
					if raw(self, "Health") > v then
						store(self, "Health", v)
					end
				end,
			},
			WalkSpeed = 16,
			JumpPower = 50,
			JumpHeight = 7.2,
			UseJumpPower = false,
			HipHeight = 2,
			AutoRotate = true,
			AutoJumpEnabled = true,
			PlatformStand = false,
			Sit = false,
			Jump = false,
			MoveDirection = RO(V0),
			RigType = Enum.HumanoidRigType.R15,
			DisplayName = "",
			DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer,
			NameDisplayDistance = 100,
			HealthDisplayDistance = 100,
			HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged,
			NameOcclusion = Enum.NameOcclusion.OccludeAll,
			MaxSlopeAngle = 89,
			FloorMaterial = RO(Enum.Material.Air),
			RootPart = COMPUTED(function(self)
				local parent = rawget(self, "_parent")
				return parent and M.findChild(parent, "HumanoidRootPart")
			end),
			SeatPart = RO(nil),
			WalkToPoint = V0,
			WalkToPart = N("Instance", "BasePart"),
			TargetPoint = V0,
			CameraOffset = V0,
			BreakJointsOnDeath = true,
			RequiresNeck = true,
			EvaluateStateMachine = true,
			AutomaticScalingEnabled = true,
		},
		methods = {
			TakeDamage = function(self, amount)
				if type(amount) ~= "number" then
					error("invalid argument #1 to 'TakeDamage' (number expected)", 2)
				end
				local parent = rawget(self, "_parent")
				if parent and parent:FindFirstChildOfClass("ForceField") then
					return
				end
				self.Health = raw(self, "Health") - amount
			end,
			MoveTo = function(self, pos, part)
				if M.typeof(pos) ~= "Vector3" then
					error("invalid argument #1 to 'MoveTo' (Vector3 expected, got " .. M.typeof(pos) .. ")", 2)
				end
				rawset(self, "_moveTarget", { pos = pos, part = part, started = M.S.now })
				rawset(self, "_moveDir", nil)
			end,
			Move = function(self, dir, _relativeToCamera)
				if M.typeof(dir) ~= "Vector3" then
					error("invalid argument #1 to 'Move' (Vector3 expected)", 2)
				end
				rawset(self, "_moveDir", dir)
				rawset(self, "_moveTarget", nil)
			end,
			ChangeState = function(self, state)
				if M.typeof(state) ~= "EnumItem" or state.EnumType ~= Enum.HumanoidStateType then
					error("invalid argument #1 to 'ChangeState' (HumanoidStateType expected)", 2)
				end
				M.setHumanoidState(self, state)
			end,
			GetState = function(self)
				return rawget(self, "_state") or Enum.HumanoidStateType.Running
			end,
			SetStateEnabled = function(self, state, enabled)
				if M.typeof(state) ~= "EnumItem" or type(enabled) ~= "boolean" then
					error("invalid arguments to 'SetStateEnabled' (HumanoidStateType, bool expected)", 2)
				end
				local t = rawget(self, "_disabledStates") or {}
				t[state] = not enabled or nil
				rawset(self, "_disabledStates", t)
			end,
			GetStateEnabled = function(self, state)
				local t = rawget(self, "_disabledStates")
				return not (t and t[state])
			end,
			EquipTool = function(self, tool)
				tool.Parent = rawget(self, "_parent")
			end,
			UnequipTools = noop,
			LoadAnimation = function(self, animation)
				return M.newAnimationTrack(self, animation)
			end,
			GetPlayingAnimationTracks = stub({}),
			GetAccessories = function(self)
				local out = {}
				local parent = rawget(self, "_parent")
				if parent then
					for _, c in parent:GetChildren() do
						if c:IsA("Accessory") then
							table.insert(out, c)
						end
					end
				end
				return out
			end,
			AddAccessory = function(self, acc)
				acc.Parent = rawget(self, "_parent")
			end,
			RemoveAccessories = function(self)
				for _, a in self:GetAccessories() do
					a:Destroy()
				end
			end,
			GetAppliedDescription = function()
				return M.create("HumanoidDescription")
			end,
			ApplyDescription = noop,
			ApplyDescriptionReset = noop,
			BuildRigFromAttachments = noop,
			GetBodyPartR15 = function(_, part)
				return Enum.BodyPartR15 and nil or part
			end,
			GetLimb = stub(nil),
			GetMoveVelocity = function(self)
				return raw(self, "MoveDirection") * raw(self, "WalkSpeed")
			end,
		},
		events = {
			"Died",
			"HealthChanged",
			"StateChanged",
			"StateEnabledChanged",
			"Running",
			"Jumping",
			"FreeFalling",
			"FallingDown",
			"GettingUp",
			"Climbing",
			"Seated",
			"PlatformStanding",
			"Swimming",
			"Strafing",
			"Ragdoll",
			"MoveToFinished",
			"Touched",
			"AnimationPlayed",
		},
	})
	class("HumanoidDescription", "Instance", {
		props = {
			HeadScale = 1,
			HeightScale = 1,
			WidthScale = 1,
			DepthScale = 1,
			BodyTypeScale = 0,
			ProportionScale = 0,
		},
	})
	class("Animator", "Instance", {
		methods = {
			LoadAnimation = function(self, animation)
				return M.newAnimationTrack(self, animation)
			end,
			GetPlayingAnimationTracks = stub({}),
		},
		events = { "AnimationPlayed" },
	})
	class("Animation", "Instance", { props = { AnimationId = "" } })
	class("AnimationTrack", "Instance", {
		notCreatable = true,
		props = {
			Animation = N("Instance", "Animation"),
			IsPlaying = RO(false),
			Length = RO(1),
			Looped = false,
			Priority = Enum.AnimationPriority.Core,
			Speed = RO(1),
			TimePosition = 0,
			WeightCurrent = RO(1),
			WeightTarget = RO(1),
		},
		methods = {
			Play = function(self)
				M.storeShared(self, "IsPlaying", true)
			end,
			Stop = function(self)
				M.storeShared(self, "IsPlaying", false)
				M.fire(M.getEvent(self, "Stopped"))
			end,
			AdjustSpeed = function(self, s)
				M.storeShared(self, "Speed", s or 1)
			end,
			AdjustWeight = noop,
			GetMarkerReachedSignal = function(self, name)
				return M.getEvent(self, "Marker:" .. tostring(name))
			end,
			GetTimeOfKeyframe = stub(0),
		},
		events = { "Stopped", "Ended", "DidLoop", "KeyframeReached" },
	})
	function M.newAnimationTrack(_owner, animation)
		if animation ~= nil and not (M.isInstance(animation) and animation:IsA("Animation")) then
			error("invalid argument #1 to 'LoadAnimation' (Animation expected)", 3)
		end
		local track = M.create("AnimationTrack")
		track._p.Animation = animation
		return track
	end

	class("Accoutrement", "Instance", { props = { AttachmentPoint = ID } })
	class("Accessory", "Accoutrement", { props = { AccessoryType = Enum.AccessoryType.Unknown } })
	class("Hat", "Accoutrement", {})
	class("Clothing", "Instance", { abstract = true, props = { Color3 = c3(255, 255, 255) } })
	class("Shirt", "Clothing", { props = { ShirtTemplate = "" } })
	class("Pants", "Clothing", { props = { PantsTemplate = "" } })
	class("ShirtGraphic", "Instance", { props = { Graphic = "", Color3 = c3(255, 255, 255) } })
	class("BodyColors", "Instance", {
		props = {
			HeadColor3 = c3(234, 184, 146),
			TorsoColor3 = c3(13, 105, 172),
			LeftArmColor3 = c3(234, 184, 146),
			RightArmColor3 = c3(234, 184, 146),
			LeftLegColor3 = c3(40, 127, 71),
			RightLegColor3 = c3(40, 127, 71),
		},
	})
	class("ForceField", "Instance", { props = { Visible = true } })
	class("Tool", "Model", {
		props = {
			RequiresHandle = true,
			CanBeDropped = true,
			Enabled = true,
			ManualActivationOnly = false,
			ToolTip = "",
			Grip = ID,
			TextureId = "",
		},
		events = { "Activated", "Deactivated", "Equipped", "Unequipped" },
		methods = { Activate = noop, Deactivate = noop },
	})
	class("Backpack", "Instance", {})
	class("StarterGear", "Instance", {})

	-- Values ----------------------------------------------------------------------------------
	class("ValueBase", "Instance", { abstract = true })
	class("StringValue", "ValueBase", { props = { Value = "" } })
	class("IntValue", "ValueBase", {
		props = {
			Value = {
				__spec = true,
				default = 0,
				type = "number",
				set = function(self, v)
					store(self, "Value", math.floor(v))
				end,
			},
		},
	})
	class("NumberValue", "ValueBase", { props = { Value = 0 } })
	class("BoolValue", "ValueBase", { props = { Value = false } })
	class("ObjectValue", "ValueBase", { props = { Value = N("Instance") } })
	class("Vector3Value", "ValueBase", { props = { Value = V0 } })
	class("CFrameValue", "ValueBase", { props = { Value = ID } })
	class("Color3Value", "ValueBase", { props = { Value = c3(0, 0, 0) } })
	class("BrickColorValue", "ValueBase", { props = { Value = T.BrickColor.new("Medium stone grey") } })

	-- Effects in the world ------------------------------------------------------------------------
	class(
		"Light",
		"Instance",
		{ abstract = true, props = { Brightness = 1, Color = c3(255, 255, 255), Enabled = true, Shadows = false } }
	)
	class("PointLight", "Light", { props = { Range = 8 } })
	class("SpotLight", "Light", { props = { Range = 16, Angle = 90, Face = Enum.NormalId.Front } })
	class("SurfaceLight", "Light", { props = { Range = 16, Angle = 90, Face = Enum.NormalId.Front } })

	local NS = T.NumberSequence
	local NR = T.NumberRange
	class("ParticleEmitter", "Instance", {
		props = {
			Rate = 20,
			Lifetime = NR.new(5, 10),
			Speed = NR.new(5),
			SpreadAngle = T.Vector2.zero,
			Size = NS.new(1),
			Transparency = NS.new(0),
			Color = T.ColorSequence.new(c3(255, 255, 255)),
			Texture = "rbxasset://textures/particles/sparkles_main.dds",
			LightEmission = 0,
			LightInfluence = 0,
			Brightness = 1,
			Rotation = NR.new(0),
			RotSpeed = NR.new(0),
			Acceleration = V0,
			Drag = 0,
			EmissionDirection = Enum.NormalId.Top,
			Enabled = true,
			LockedToPart = false,
			VelocityInheritance = 0,
			ZOffset = 0,
			Orientation = Enum.ParticleOrientation.FacingCamera,
			Shape = Enum.ParticleEmitterShape.Box,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
			ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward,
			ShapePartial = 1,
			Squash = NS.new(0),
			TimeScale = 1,
			WindAffectsDrag = false,
			FlipbookLayout = ANY(nil),
			FlipbookMode = ANY(nil),
			FlipbookFramerate = NR.new(1),
			FlipbookStartRandom = false,
		},
		methods = {
			Emit = function(self, n)
				if n ~= nil and type(n) ~= "number" then
					error("invalid argument #1 to 'Emit' (number expected)", 2)
				end
				rawset(self, "_emitted", (rawget(self, "_emitted") or 0) + (n or 16))
			end,
			Clear = noop,
		},
	})
	class("Fire", "Instance", {
		props = {
			Size = 5,
			Heat = 9,
			Color = c3(236, 139, 70),
			SecondaryColor = c3(139, 80, 55),
			Enabled = true,
			TimeScale = 1,
		},
	})
	class("Smoke", "Instance", {
		props = {
			Size = 1,
			Opacity = 0.5,
			RiseVelocity = 1,
			Color = c3(255, 255, 255),
			Enabled = true,
			TimeScale = 1,
		},
	})
	class("Sparkles", "Instance", { props = { SparkleColor = c3(144, 25, 255), Enabled = true, TimeScale = 1 } })
	class("Explosion", "Instance", {
		props = {
			Position = V0,
			BlastRadius = 4,
			BlastPressure = 500000,
			DestroyJointRadiusPercent = 1,
			ExplosionType = Enum.ExplosionType.Craters,
			Visible = true,
		},
		events = { "Hit" },
	})
	class("Beam", "Instance", {
		props = {
			Attachment0 = N("Instance", "Attachment"),
			Attachment1 = N("Instance", "Attachment"),
			Color = T.ColorSequence.new(c3(255, 255, 255)),
			Transparency = NS.new(0.5),
			Width0 = 1,
			Width1 = 1,
			CurveSize0 = 0,
			CurveSize1 = 0,
			FaceCamera = false,
			Segments = 10,
			LightEmission = 0,
			LightInfluence = 0,
			Brightness = 1,
			Texture = "",
			TextureLength = 1,
			TextureMode = Enum.TextureMode.Stretch,
			TextureSpeed = 1,
			Enabled = true,
			ZOffset = 0,
		},
	})
	class("Trail", "Instance", {
		props = {
			Attachment0 = N("Instance", "Attachment"),
			Attachment1 = N("Instance", "Attachment"),
			Color = T.ColorSequence.new(c3(255, 255, 255)),
			Transparency = NS.new(0.5),
			Lifetime = 2,
			MinLength = 0.1,
			MaxLength = 0,
			WidthScale = NS.new(1),
			FaceCamera = false,
			LightEmission = 0,
			LightInfluence = 0,
			Brightness = 1,
			Texture = "",
			TextureLength = 1,
			TextureMode = Enum.TextureMode.Stretch,
			Enabled = true,
		},
		methods = { Clear = noop },
	})
	class(
		"DataModelMesh",
		"Instance",
		{ abstract = true, props = { Scale = v3(1, 1, 1), Offset = V0, VertexColor = v3(1, 1, 1) } }
	)
	class("SpecialMesh", "DataModelMesh", { props = { MeshType = Enum.MeshType.Head, MeshId = "", TextureId = "" } })
	class("BlockMesh", "DataModelMesh", {})
	class("CylinderMesh", "DataModelMesh", {})
	class("FaceInstance", "Instance", { abstract = true, props = { Face = Enum.NormalId.Front } })
	class("Decal", "FaceInstance", {
		props = {
			Texture = "",
			Color3 = c3(255, 255, 255),
			Transparency = 0,
			ZIndex = 1,
			LocalTransparencyModifier = 0,
		},
	})
	class("Texture", "Decal", { props = { StudsPerTileU = 2, StudsPerTileV = 2, OffsetStudsU = 0, OffsetStudsV = 0 } })
	class(
		"SurfaceAppearance",
		"Instance",
		{ props = { ColorMap = "", MetalnessMap = "", NormalMap = "", RoughnessMap = "", Color = c3(255, 255, 255) } }
	)
	class("Highlight", "Instance", {
		props = {
			Adornee = N("Instance"),
			FillColor = c3(255, 0, 0),
			FillTransparency = 0.5,
			OutlineColor = c3(255, 255, 255),
			OutlineTransparency = 0,
			DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
			Enabled = true,
		},
	})
	class("SelectionBox", "Instance", {
		props = {
			Adornee = N("Instance"),
			Color3 = c3(13, 105, 172),
			LineThickness = 0.15,
			SurfaceColor3 = c3(13, 105, 172),
			SurfaceTransparency = 1,
			Transparency = 0,
			Visible = true,
		},
	})
	class("ClickDetector", "Instance", {
		props = { MaxActivationDistance = 32, CursorIcon = "" },
		events = { "MouseClick", "RightMouseClick", "MouseHoverEnter", "MouseHoverLeave" },
	})

	-- Sound ---------------------------------------------------------------------------------------
	class("Sound", "Instance", {
		props = {
			SoundId = "",
			Volume = 0.5,
			Playing = false,
			Looped = false,
			PlaybackSpeed = 1,
			Pitch = 1,
			TimePosition = 0,
			TimeLength = RO(0),
			IsPlaying = COMPUTED(function(self)
				return raw(self, "Playing")
			end),
			IsLoaded = RO(true),
			IsPaused = COMPUTED(function(self)
				return not raw(self, "Playing")
			end),
			RollOffMode = Enum.RollOffMode.Inverse,
			RollOffMinDistance = 10,
			RollOffMaxDistance = 10000,
			EmitterSize = 10,
			MaxDistance = 10000,
			SoundGroup = N("Instance", "SoundGroup"),
			PlayOnRemove = false,
			PlaybackLoudness = RO(0),
		},
		methods = {
			Play = function(self)
				store(self, "Playing", true)
				M.fire(M.getEvent(self, "Played"), raw(self, "SoundId"))
			end,
			Stop = function(self)
				store(self, "Playing", false)
				store(self, "TimePosition", 0)
				M.fire(M.getEvent(self, "Stopped"), raw(self, "SoundId"))
			end,
			Pause = function(self)
				store(self, "Playing", false)
			end,
			Resume = function(self)
				store(self, "Playing", true)
			end,
		},
		events = { "Ended", "Played", "Loaded", "Stopped", "DidLoop", "Paused", "Resumed" },
	})
	class("SoundGroup", "Instance", { props = { Volume = 0.5 } })
	class("SoundEffect", "Instance", { abstract = true, props = { Enabled = true, Priority = 0 } })
	class("EqualizerSoundEffect", "SoundEffect", { props = { HighGain = 0, MidGain = 0, LowGain = 0 } })
	class(
		"ReverbSoundEffect",
		"SoundEffect",
		{ props = { DecayTime = 1.5, Density = 1, Diffusion = 1, DryLevel = -6, WetLevel = 0 } }
	)

	-- Remotes / bindables --------------------------------------------------------------------------
	class("RemoteEvent", "Instance", {
		methods = {
			FireServer = function(self, ...)
				M.remoteFireServer(self, ...)
			end,
			FireClient = function(self, player, ...)
				M.remoteFireClient(self, player, ...)
			end,
			FireAllClients = function(self, ...)
				M.remoteFireAllClients(self, ...)
			end,
		},
		events = { "OnServerEvent", "OnClientEvent" },
	})
	class("UnreliableRemoteEvent", "RemoteEvent", {})
	class("RemoteFunction", "Instance", {
		props = {
			OnServerInvoke = { __spec = true, type = "function", nilable = true, writeOnly = true },
			OnClientInvoke = { __spec = true, type = "function", nilable = true, writeOnly = true },
		},
		methods = {
			InvokeServer = function(self, ...)
				return M.remoteInvokeServer(self, ...)
			end,
			InvokeClient = function(self, player, ...)
				return M.remoteInvokeClient(self, player, ...)
			end,
		},
	})
	class("BindableEvent", "Instance", {
		methods = {
			Fire = function(self, ...)
				M.fire(M.getEvent(self, "Event"), M.copyArgs(nil, ...))
			end,
		},
		events = { "Event" },
	})
	class("BindableFunction", "Instance", {
		props = { OnInvoke = { __spec = true, type = "function", nilable = true, writeOnly = true } },
		methods = {
			Invoke = function(self, ...)
				local fn = self._p.OnInvoke
				if not fn then
					error("BindableFunction:Invoke has no OnInvoke callback", 2)
				end
				return fn(M.copyArgs(nil, ...))
			end,
		},
	})

	-- ProximityPrompt -------------------------------------------------------------------------------
	class("ProximityPrompt", "Instance", {
		props = {
			ActionText = "Interact",
			ObjectText = "",
			KeyboardKeyCode = Enum.KeyCode.E,
			GamepadKeyCode = Enum.KeyCode.ButtonX,
			HoldDuration = 0,
			MaxActivationDistance = 10,
			RequiresLineOfSight = true,
			Enabled = true,
			Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton,
			Style = Enum.ProximityPromptStyle.Default,
			UIOffset = T.Vector2.zero,
			ClickablePrompt = true,
			AutoLocalize = true,
		},
		methods = {
			InputHoldBegin = noop,
			InputHoldEnd = noop,
		},
		events = {
			"Triggered",
			"TriggerEnded",
			"PromptButtonHoldBegan",
			"PromptButtonHoldEnded",
			"PromptShown",
			"PromptHidden",
		},
	})

	-- Scripts -----------------------------------------------------------------------------------------
	class("LuaSourceContainer", "Instance", { abstract = true })
	class(
		"BaseScript",
		"LuaSourceContainer",
		{ abstract = true, props = { Disabled = false, Enabled = true, RunContext = ANY(nil) } }
	)
	class("Script", "BaseScript", {})
	class("LocalScript", "Script", {})
	class("ModuleScript", "LuaSourceContainer", {})

	-- GUI ---------------------------------------------------------------------------------------------
	local U2 = T.UDim2
	local V2 = T.Vector2
	class("GuiBase2d", "Instance", {
		abstract = true,
		props = {
			AbsoluteSize = COMPUTED(function(self)
				return M.guiAbsoluteSize(self)
			end),
			AbsolutePosition = COMPUTED(function(self)
				return M.guiAbsolutePosition(self)
			end),
			AbsoluteRotation = RO(0),
			AutoLocalize = true,
			RootLocalizationTable = N("Instance"),
			SelectionGroup = false,
			SelectionBehaviorUp = ANY(nil),
			SelectionBehaviorDown = ANY(nil),
			SelectionBehaviorLeft = ANY(nil),
			SelectionBehaviorRight = ANY(nil),
		},
	})
	class("LayerCollector", "GuiBase2d", {
		abstract = true,
		props = { Enabled = true, ResetOnSpawn = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling },
	})
	class("ScreenGui", "LayerCollector", {
		props = {
			IgnoreGuiInset = false,
			DisplayOrder = 0,
			ScreenInsets = ANY(nil),
			SafeAreaCompatibility = ANY(nil),
			ClipToDeviceSafeArea = true,
		},
	})
	class("BillboardGui", "LayerCollector", {
		props = {
			Adornee = N("Instance"),
			Size = U2.new(),
			StudsOffset = V0,
			StudsOffsetWorldSpace = V0,
			ExtentsOffset = V0,
			ExtentsOffsetWorldSpace = V0,
			SizeOffset = V2.zero,
			AlwaysOnTop = false,
			MaxDistance = math.huge,
			DistanceLowerLimit = 0,
			DistanceUpperLimit = -1,
			DistanceStep = 0,
			LightInfluence = 0,
			Brightness = 1,
			ClipsDescendants = false,
			Active = false,
			PlayerToHideFrom = N("Instance", "Player"),
		},
	})
	class(
		"SurfaceGuiBase",
		"LayerCollector",
		{ abstract = true, props = { Adornee = N("Instance"), Face = Enum.NormalId.Front, Active = true } }
	)
	class("SurfaceGui", "SurfaceGuiBase", {
		props = {
			SizingMode = Enum.SurfaceGuiSizingMode.FixedSize,
			PixelsPerStud = 50,
			CanvasSize = V2.new(800, 600),
			AlwaysOnTop = false,
			LightInfluence = 1,
			Brightness = 1,
			ClipsDescendants = true,
			ZOffset = 0,
			ToolPunchThroughDistance = 0,
			MaxDistance = 1000,
		},
	})
	class("GuiObject", "GuiBase2d", {
		abstract = true,
		props = {
			Size = U2.new(),
			Position = U2.new(),
			AnchorPoint = V2.zero,
			BackgroundColor3 = c3(163, 162, 165),
			BackgroundColor = COMPUTED(function(self)
				return T.BrickColor.new(raw(self, "BackgroundColor3"))
			end, function(self, v)
				store(self, "BackgroundColor3", v.Color)
			end, "BrickColor"),
			BackgroundTransparency = 0,
			BorderColor3 = c3(27, 42, 53),
			BorderSizePixel = 1,
			BorderMode = Enum.BorderMode.Outline,
			Visible = true,
			ZIndex = 1,
			LayoutOrder = 0,
			Rotation = 0,
			ClipsDescendants = false,
			Active = false,
			AutomaticSize = Enum.AutomaticSize.None,
			SizeConstraint = Enum.SizeConstraint.RelativeXY,
			Selectable = false,
			SelectionOrder = 0,
			Interactable = true,
			Transparency = COMPUTED(function(self)
				return raw(self, "BackgroundTransparency")
			end, function(self, v)
				store(self, "BackgroundTransparency", v)
			end, "number"),
			NextSelectionUp = N("Instance"),
			NextSelectionDown = N("Instance"),
			NextSelectionLeft = N("Instance"),
			NextSelectionRight = N("Instance"),
			SelectionImageObject = N("Instance"),
		},
		methods = {
			TweenPosition = function(self, pos)
				self.Position = pos
				return true
			end,
			TweenSize = function(self, size)
				self.Size = size
				return true
			end,
			TweenSizeAndPosition = function(self, size, pos)
				self.Size = size
				self.Position = pos
				return true
			end,
		},
		events = {
			"InputBegan",
			"InputChanged",
			"InputEnded",
			"MouseEnter",
			"MouseLeave",
			"MouseMoved",
			"MouseWheelForward",
			"MouseWheelBackward",
			"TouchTap",
			"TouchLongPress",
			"TouchPan",
			"TouchPinch",
			"TouchRotate",
			"TouchSwipe",
			"SelectionGained",
			"SelectionLost",
		},
	})
	class("Frame", "GuiObject", { props = { Style = Enum.FrameStyle.Custom } })
	class("ScrollingFrame", "GuiObject", {
		props = {
			CanvasSize = U2.new(0, 0, 2, 0),
			CanvasPosition = V2.zero,
			ScrollBarThickness = 12,
			ScrollingDirection = Enum.ScrollingDirection.XY,
			AutomaticCanvasSize = Enum.AutomaticSize.None,
			ScrollBarImageColor3 = c3(255, 255, 255),
			ScrollBarImageTransparency = 0,
			ScrollingEnabled = true,
			ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
			VerticalScrollBarInset = Enum.ScrollBarInset.None,
			HorizontalScrollBarInset = Enum.ScrollBarInset.None,
			VerticalScrollBarPosition = ANY(nil),
			TopImage = "",
			MidImage = "",
			BottomImage = "",
			AbsoluteCanvasSize = COMPUTED(function(self)
				return M.guiAbsoluteSize(self)
			end),
			AbsoluteWindowSize = COMPUTED(function(self)
				return M.guiAbsoluteSize(self)
			end),
		},
	})
	class("CanvasGroup", "GuiObject", { props = { GroupColor3 = c3(255, 255, 255), GroupTransparency = 0 } })
	local textProps = {
		Text = "Label",
		TextColor3 = c3(27, 42, 53),
		TextSize = 14,
		TextScaled = false,
		TextWrapped = false,
		TextWrap = false,
		Font = Enum.Font.Legacy,
		FontFace = T.Font.new("rbxasset://fonts/families/LegacyArial.json"),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTransparency = 0,
		TextStrokeColor3 = c3(0, 0, 0),
		TextStrokeTransparency = 1,
		RichText = false,
		LineHeight = 1,
		MaxVisibleGraphemes = -1,
		TextTruncate = Enum.TextTruncate.None,
		TextDirection = Enum.TextDirection.Auto,
		TextBounds = COMPUTED(function(self)
			local text = tostring(raw(self, "Text"))
			local size = raw(self, "TextSize")
			return V2.new(#text * size * 0.5, size)
		end),
		TextFits = RO(true),
		ContentText = COMPUTED(function(self)
			return raw(self, "Text")
		end),
		LocalizedText = COMPUTED(function(self)
			return raw(self, "Text")
		end),
	}
	class("TextLabel", "GuiObject", { props = textProps })
	local buttonProps = { AutoButtonColor = true, Modal = false, Selected = false, Style = Enum.ButtonStyle.Custom }
	local buttonEvents = {
		"Activated",
		"MouseButton1Click",
		"MouseButton1Down",
		"MouseButton1Up",
		"MouseButton2Click",
		"MouseButton2Down",
		"MouseButton2Up",
	}
	class("GuiButton", "GuiObject", { abstract = true, props = buttonProps, events = buttonEvents })
	class("TextButton", "GuiButton", { props = textProps })
	class("TextBox", "GuiObject", {
		props = (function()
			local p = table.clone(textProps)
			p.PlaceholderText = ""
			p.PlaceholderColor3 = c3(178, 178, 178)
			p.ClearTextOnFocus = true
			p.MultiLine = false
			p.TextEditable = true
			p.CursorPosition = 1
			p.SelectionStart = -1
			return p
		end)(),
		methods = {
			CaptureFocus = noop,
			ReleaseFocus = noop,
			IsFocused = stub(false),
		},
		events = { "Focused", "FocusLost", "ReturnPressedFromOnScreenKeyboard" },
	})
	local imageProps = {
		Image = "",
		ImageColor3 = c3(255, 255, 255),
		ImageTransparency = 0,
		ScaleType = Enum.ScaleType.Stretch,
		SliceCenter = T.Rect.new(0, 0, 0, 0),
		SliceScale = 1,
		TileSize = U2.new(1, 0, 1, 0),
		ImageRectOffset = V2.zero,
		ImageRectSize = V2.zero,
		ResampleMode = Enum.ResamplerMode.Default,
		IsLoaded = RO(true),
	}
	class("ImageLabel", "GuiObject", { props = imageProps })
	class("ImageButton", "GuiButton", {
		props = (function()
			local p = table.clone(imageProps)
			p.HoverImage = ""
			p.PressedImage = ""
			return p
		end)(),
	})
	class("ViewportFrame", "GuiObject", {
		props = {
			CurrentCamera = N("Instance", "Camera"),
			Ambient = c3(200, 200, 200),
			LightColor = c3(140, 140, 140),
			LightDirection = v3(-1, -1, -1),
			ImageColor3 = c3(255, 255, 255),
			ImageTransparency = 0,
		},
	})
	class("UIComponent", "Instance", { abstract = true })
	class("UICorner", "UIComponent", { props = { CornerRadius = T.UDim.new(0, 8) } })
	class("UIStroke", "UIComponent", {
		props = {
			Color = c3(0, 0, 0),
			Thickness = 1,
			Transparency = 0,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			LineJoinMode = Enum.LineJoinMode.Round,
			Enabled = true,
		},
	})
	class("UIGradient", "UIComponent", {
		props = {
			Color = T.ColorSequence.new(c3(255, 255, 255)),
			Transparency = NS.new(0),
			Rotation = 0,
			Offset = V2.zero,
			Enabled = true,
		},
	})
	class("UIPadding", "UIComponent", {
		props = {
			PaddingTop = T.UDim.new(),
			PaddingBottom = T.UDim.new(),
			PaddingLeft = T.UDim.new(),
			PaddingRight = T.UDim.new(),
		},
	})
	class("UIScale", "UIComponent", { props = { Scale = 1 } })
	class("UIConstraint", "UIComponent", { abstract = true })
	class("UIAspectRatioConstraint", "UIConstraint", {
		props = {
			AspectRatio = 1,
			AspectType = Enum.AspectType.FitWithinMaxSize,
			DominantAxis = Enum.DominantAxis.Width,
		},
	})
	class("UISizeConstraint", "UIConstraint", { props = { MinSize = V2.zero, MaxSize = V2.new(math.huge, math.huge) } })
	class("UITextSizeConstraint", "UIConstraint", { props = { MinTextSize = 1, MaxTextSize = 100 } })
	class(
		"UIFlexItem",
		"UIComponent",
		{ props = { FlexMode = ANY(nil), GrowRatio = 0, ShrinkRatio = 0, ItemLineAlignment = ANY(nil) } }
	)
	class("UILayout", "UIComponent", { abstract = true })
	class("UIGridStyleLayout", "UILayout", {
		abstract = true,
		props = {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.Name,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Top,
			AbsoluteContentSize = COMPUTED(function(self)
				local parent = rawget(self, "_parent")
				return if parent then M.guiAbsoluteSize(parent) else V2.zero
			end),
		},
	})
	class("UIListLayout", "UIGridStyleLayout", {
		props = {
			Padding = T.UDim.new(),
			Wraps = false,
			HorizontalFlex = ANY(nil),
			VerticalFlex = ANY(nil),
			ItemLineAlignment = ANY(nil),
		},
	})
	class("UIGridLayout", "UIGridStyleLayout", {
		props = {
			CellSize = U2.new(0, 100, 0, 100),
			CellPadding = U2.new(0, 5, 0, 5),
			StartCorner = Enum.StartCorner.TopLeft,
			FillDirectionMaxCells = 0,
			AbsoluteCellSize = RO(V2.new(100, 100)),
			AbsoluteCellCount = RO(V2.new(1, 1)),
		},
	})
	class(
		"UIPageLayout",
		"UIGridStyleLayout",
		{ props = { Animated = true, Circular = false, Padding = T.UDim.new() } }
	)
	class("UITableLayout", "UIGridStyleLayout", { props = { Padding = U2.new() } })

	-- Lighting effects -------------------------------------------------------------------------------
	class("PostEffect", "Instance", { abstract = true, props = { Enabled = true } })
	class("BlurEffect", "PostEffect", { props = { Size = 24 } })
	class(
		"ColorCorrectionEffect",
		"PostEffect",
		{ props = { Brightness = 0, Contrast = 0, Saturation = 0, TintColor = c3(255, 255, 255) } }
	)
	class("BloomEffect", "PostEffect", { props = { Intensity = 1, Size = 24, Threshold = 2 } })
	class("SunRaysEffect", "PostEffect", { props = { Intensity = 0.25, Spread = 1 } })
	class(
		"DepthOfFieldEffect",
		"PostEffect",
		{ props = { FarIntensity = 0.75, FocusDistance = 0.05, InFocusRadius = 10, NearIntensity = 0.75 } }
	)
	class("ColorGradingEffect", "PostEffect", { props = { TonemapperPreset = ANY(nil) } })
	class("Atmosphere", "Instance", {
		props = { Density = 0.395, Offset = 0, Color = c3(199, 170, 107), Decay = c3(92, 60, 13), Glare = 0, Haze = 0 },
	})
	class("Clouds", "Instance", { props = { Cover = 0.5, Density = 0.7, Color = c3(255, 255, 255), Enabled = true } })
	class("Sky", "Instance", {
		props = {
			SkyboxBk = "",
			SkyboxDn = "",
			SkyboxFt = "",
			SkyboxLf = "",
			SkyboxRt = "",
			SkyboxUp = "",
			SunTextureId = "",
			MoonTextureId = "",
			SunAngularSize = 21,
			MoonAngularSize = 11,
			StarCount = 3000,
			CelestialBodiesShown = true,
			SkyboxOrientation = V0,
		},
	})

	-- Camera ----------------------------------------------------------------------------------------
	class("Camera", "PVInstance", {
		props = {
			CFrame = T.CFrame.new(0, 20, 20),
			Focus = ID,
			FieldOfView = 70,
			DiagonalFieldOfView = 88,
			MaxAxisFieldOfView = 70,
			FieldOfViewMode = ANY(nil),
			CameraType = Enum.CameraType.Custom,
			CameraSubject = N("Instance"),
			ViewportSize = RO(V2.new(1920, 1080)),
			NearPlaneZ = RO(-0.1),
			HeadLocked = true,
			HeadScale = 1,
			VRTiltAndRollEnabled = false,
		},
		methods = {
			ViewportPointToRay = function(self, x, y, depth)
				return M.cameraRay(self, x, y, depth)
			end,
			ScreenPointToRay = function(self, x, y, depth)
				return M.cameraRay(self, x, y + 36, depth)
			end,
			WorldToViewportPoint = function(self, p)
				return M.cameraProject(self, p)
			end,
			WorldToScreenPoint = function(self, p)
				return M.cameraProject(self, p)
			end,
			GetPartsObscuringTarget = stub({}),
			ZoomToExtents = noop,
			Interpolate = noop,
			GetRenderCFrame = function(self)
				return raw(self, "CFrame")
			end,
		},
		events = { "InterpolationFinished" },
	})

	-- Player-side containers ---------------------------------------------------------------------------
	class("BasePlayerGui", "Instance", { abstract = true })
	class("PlayerGui", "BasePlayerGui", {
		notCreatable = true,
		props = {
			ScreenOrientation = ANY(nil),
			SelectionImageObject = N("Instance"),
			CurrentScreenOrientation = ANY(nil),
		},
		methods = {
			GetTopbarTransparency = stub(0),
			SetTopbarTransparency = noop,
		},
		events = { "TopbarTransparencyChangedSignal" },
	})
	class("PlayerScripts", "Instance", { notCreatable = true })
	class("Team", "Instance", {
		props = { TeamColor = T.BrickColor.new("White"), AutoAssignable = true },
		events = { "PlayerAdded", "PlayerRemoved" },
	})

	class("Mouse", "Instance", {
		notCreatable = true,
		props = {
			Hit = ID,
			Target = N("Instance"),
			TargetFilter = N("Instance"),
			X = 960,
			Y = 540,
			Origin = ID,
			UnitRay = ANY(nil),
			Icon = "",
			ViewSizeX = 1920,
			ViewSizeY = 1080,
		},
		events = {
			"Button1Down",
			"Button1Up",
			"Button2Down",
			"Button2Up",
			"Move",
			"WheelForward",
			"WheelBackward",
			"Idle",
		},
	})
	-- Unused fmt guard (keeps selene quiet if helpers above change).
	local _ = fmt
end
