using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using HarmonyLib;
using VRage.Collections;
using VRage.Game.Components;
using VRage.Game.Entity;
using Xunit;

namespace SentisClientOptimisation.Tests
{
    /// <summary>The fixes patched once into the test process against the game client's own assemblies.</summary>
    public sealed class Patched
    {
        public readonly Dictionary<string, Exception> Failed = new Dictionary<string, Exception>();

        public Patched()
        {
            var harmony = new Harmony(Plugin.Id + ".tests");
            void Try(string name, Action<Harmony> patch)
            {
                try { patch(harmony); }
                catch (Exception e) { Failed[name] = e; }
            }
            Try("BulkChildDelete", BulkChildDelete.Patch);
            Try("ConveyorCloseUnsubscribe", ConveyorCloseUnsubscribe.Patch);
            Try("PoolCap", PoolCap.Patch);
            Try("VoxelCacheSave", VoxelCacheSave.Patch);
            Try("GridLoadAsync", GridLoadAsync.Patch);
            Try("ProjectionPreclone", ProjectionPreclone.Patch);
            Try("ThrustConveyorScc", ThrustConveyorScc.Patch);
            Try("VoxelLoadAsync", VoxelLoadAsync.Patch);
            Try("PlanetDetailNoGc", PlanetDetailNoGc.Patch);
            Try("GroupPowerOnce", GroupPowerOnce.Patch);
            Try("LinePowerOnce", LinePowerOnce.Patch);
            Try("PowerReadOnce", PowerReadOnce.Patch);
        }
    }

    [CollectionDefinition("patched", DisableParallelization = true)]
    public sealed class PatchedCollection : ICollectionFixture<Patched>
    {
    }

    [Collection("patched")]
    public sealed class PatchTests
    {
        private readonly Patched _patched;

        public PatchTests(Patched patched) => _patched = patched;

        [Theory]
        [InlineData("BulkChildDelete")]
        [InlineData("ConveyorCloseUnsubscribe")]
        [InlineData("PoolCap")]
        [InlineData("VoxelCacheSave")]
        [InlineData("GridLoadAsync")]
        [InlineData("ProjectionPreclone")]
        [InlineData("ThrustConveyorScc")]
        [InlineData("VoxelLoadAsync")]
        [InlineData("PlanetDetailNoGc")]
        [InlineData("GroupPowerOnce")]
        [InlineData("LinePowerOnce")]
        [InlineData("PowerReadOnce")]
        public void Every_fix_fits_the_game_client(string fix)
        {
            Assert.False(_patched.Failed.TryGetValue(fix, out var e), fix + ": " + e);
        }

        [Fact]
        public void The_entity_delete_goes_through_the_fix()
        {
            var info = Harmony.GetPatchInfo(AccessTools.Method(typeof(MyEntity), nameof(MyEntity.Delete), Type.EmptyTypes));
            Assert.Contains(info.Transpilers, p => p.PatchMethod.DeclaringType == typeof(BulkChildDelete));
        }
    }

    [Collection("patched")]
    public sealed class PoolTests
    {
        private sealed class Buffer
        {
        }

        private sealed class OtherBuffer
        {
        }

        private sealed class Allocator<T> : IMyElementAllocator<T> where T : class, new()
        {
            public int Allocated, Disposed;
            public bool ExplicitlyDisposeAllElements => false;
            public T Allocate(int bucketId) { Allocated++; return new T(); }
            public void Dispose(T instance) => Disposed++;
            public void Init(T instance) { }
            public int GetBytes(T instance) => 16;
            public int GetBucketId(T instance) => 0;
        }

        public PoolTests(Patched patched) => Assert.Empty(patched.Failed);

        private static double TakeBack(int n, int max, out Allocator<Buffer> allocator)
        {
            allocator = new Allocator<Buffer>();
            var pool = new MyConcurrentBucketPool<Buffer>("test", allocator, max);
            var buffers = Enumerable.Range(0, n).Select(_ => pool.Get(0)).ToList();
            var clock = Stopwatch.StartNew();
            foreach (var buffer in buffers) pool.Return(buffer);
            return clock.Elapsed.TotalMilliseconds;
        }

        /// <summary>
        /// 30 000 buffers given back to a pool with no maximum, as the game's network pools: the count before each walks
        /// all those pooled (N²); with the cap it walks at most 512, and what is over is freed.
        /// </summary>
        [Fact]
        public void A_capped_pool_takes_back_without_walking_all_pooled()
        {
            const int n = 30000;
            var uncapped = TakeBack(n, int.MaxValue, out var all);
            var capped = TakeBack(n, PoolCap.Cap, out var some);
            Assert.Equal(0, all.Disposed);
            Assert.Equal(n - PoolCap.Cap, some.Disposed);
            Assert.True(capped * 5 < uncapped, $"{n} buffers taken back: capped {capped:0} ms, uncapped {uncapped:0} ms");
        }

        [Fact]
        public void The_game_network_pools_are_capped()
        {
            Assert.Equal(PoolCap.Pools.Length, PoolCap.Capped.Count);
            foreach (var (type, field) in PoolCap.Pools)
            {
                var pool = Type.GetType(type).GetField(field, System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public).GetValue(null);
                var t = pool.GetType();
                while (!(t.IsGenericType && t.GetGenericTypeDefinition() == typeof(MyConcurrentBucketPool<>))) t = t.BaseType;
                Assert.Equal(PoolCap.Cap, (int)t.GetField("m_maxPooledInstances", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic).GetValue(pool));
            }
        }

        /// <summary>A pool with its own maximum keeps it.</summary>
        [Fact]
        public void A_pool_with_a_maximum_keeps_its_own()
        {
            var pool = new MyConcurrentBucketPool<OtherBuffer>("test-max", new Allocator<OtherBuffer>(), 10);
            Assert.True(PoolCap.SetCap(pool));
            var max = typeof(MyConcurrentBucketPool<OtherBuffer>).GetField("m_maxPooledInstances", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
            Assert.Equal(10, (int)max.GetValue(pool));
            Assert.False(PoolCap.SetCap(new object()));
        }
    }

    public sealed class SubscriberTests
    {
        private sealed class Owner
        {
            public event Action Changed;
            public int Raise() { var n = 0; Changed?.Invoke(); return Changed?.GetInvocationList().Length ?? n; }
        }

        private sealed class Listener
        {
            public int Calls;
            public void On() => Calls++;
        }

        private static int _static;
        private static void OnStatic() => _static++;

        [Fact]
        public void Handlers_of_the_targets_given_are_taken_out_at_once_and_the_rest_kept_in_order()
        {
            var owner = new Owner();
            var listeners = Enumerable.Range(0, 5).Select(_ => new Listener()).ToList();
            foreach (var l in listeners) owner.Changed += l.On;
            owner.Changed += OnStatic;
            var gone = Subscribers.NewSet(2);
            gone.Add(listeners[1]);
            gone.Add(listeners[3]);
            Subscribers.RemoveTargets(owner, AccessTools.Field(typeof(Owner), "Changed"), gone);
            Assert.Equal(4, owner.Raise());
            Assert.Equal(new[] { 1, 0, 1, 0, 1 }, listeners.Select(l => l.Calls));
            Assert.Equal(1, _static);
        }

        [Fact]
        public void All_handlers_taken_out_leave_the_event_empty()
        {
            var owner = new Owner();
            var l = new Listener();
            owner.Changed += l.On;
            var gone = Subscribers.NewSet();
            gone.Add(l);
            Subscribers.RemoveTargets(owner, AccessTools.Field(typeof(Owner), "Changed"), gone);
            Assert.Null(AccessTools.Field(typeof(Owner), "Changed").GetValue(owner));
        }
    }

    [Collection("patched")]
    public sealed class ChildRemoveTests
    {
        public ChildRemoveTests(Patched patched) => Assert.Empty(patched.Failed);

        /// <summary>The last child taken off the end; any other the game's way; the list the same as the game would leave it.</summary>
        [Fact]
        public void The_last_child_comes_off_the_end_any_other_as_the_game_takes_it()
        {
            var parent = new MyHierarchyComponentBase();
            var children = AccessTools.FieldRefAccess<MyHierarchyComponentBase, List<MyHierarchyComponentBase>>("m_children")(parent);
            var kids = Enumerable.Range(0, 5).Select(_ => new MyHierarchyComponentBase()).ToList();
            children.AddRange(kids);
            var fromEnd0 = BulkChildDelete.FromEnd;
            BulkChildDelete.RemoveChild(parent, kids[4]);
            BulkChildDelete.RemoveChild(parent, kids[1]);
            BulkChildDelete.RemoveChild(parent, kids[3]);
            Assert.Equal(new[] { kids[0], kids[2] }, children);
            Assert.Equal(2, BulkChildDelete.FromEnd - fromEnd0);
        }
    }

    public sealed class StreamCopyTests
    {
        /// <summary>The copy of a stream from any bit reads the same as the stream from there.</summary>
        [Theory]
        [InlineData(0)]
        [InlineData(1)]
        [InlineData(7)]
        [InlineData(13)]
        public void A_copy_from_the_read_position_reads_what_the_stream_would(int skip)
        {
            var stream = new VRage.Library.Collections.BitStream();
            stream.ResetWrite();
            for (var i = 0; i < skip; i++) stream.WriteBool(i % 2 == 0);
            stream.WriteBool(false);
            for (var i = 0; i < 5000; i++) stream.WriteInt64(i * 7919L);
            stream.WriteDouble(12345.678);
            stream.Terminate();
            stream.ResetRead();
            for (var i = 0; i < skip; i++) stream.ReadBool();
            var copy = GridLoadAsync.CopyFromPosition(stream);
            Assert.False(copy.ReadBool());
            for (var i = 0; i < 5000; i++) Assert.Equal(i * 7919L, copy.ReadInt64());
            Assert.Equal(12345.678, copy.ReadDouble());
            Assert.True(copy.CheckTerminator());
            copy.Dispose();
            stream.Dispose();
        }
    }

    [Collection("patched")]
    public sealed class PrecloneTests
    {
        public PrecloneTests(Patched patched) => Assert.Empty(patched.Failed);

        /// <summary>A copy made before is taken once, by its original; the next asks for a copy anew.</summary>
        [Fact]
        public void A_copy_made_before_is_taken_once()
        {
            var original = new VRage.Game.MyObjectBuilder_CubeGrid();
            var copy = new VRage.Game.MyObjectBuilder_CubeGrid();
            ProjectionPreclone.Keep(original, copy);
            var taken0 = ProjectionPreclone.Taken;
            Assert.Same(copy, ProjectionPreclone.Take(original));
            Assert.Equal(1, ProjectionPreclone.Taken - taken0);
            Exception again = null;
            try { Assert.NotSame(copy, ProjectionPreclone.Take(original)); }
            catch (Exception e) { again = e; }   // the game's Clone needs the game's serializers, not set up here
            Assert.Equal(1, ProjectionPreclone.Taken - taken0);
        }
    }

    [Collection("patched")]
    public sealed class PowerReadOnceTests
    {
        public PowerReadOnceTests(Patched patched) => Assert.Empty(patched.Failed);

        /// <summary>The sound of a grid and its upgrade modules ask the state of its power through the fix.</summary>
        [Fact]
        public void The_readers_of_a_grid_power_ask_through_the_fix()
        {
            foreach (var method in new[]
                     {
                         AccessTools.Method(typeof(Sandbox.Game.EntityComponents.MyShipSoundComponent), "UpdateState"),
                         AccessTools.Method(typeof(SpaceEngineers.Game.Entities.Blocks.MyUpgradeModule), "UpdateBeforeSimulation100"),
                     })
                Assert.Contains(Harmony.GetPatchInfo(method).Transpilers, p => p.PatchMethod.DeclaringType == typeof(PowerReadOnce));
        }

        /// <summary>An answer is kept for its frame only: the frame before and the frame after ask again.</summary>
        [Fact]
        public void An_answer_is_kept_for_its_frame_only()
        {
            var distributor = new Sandbox.Game.EntityComponents.MyResourceDistributorComponent("test");
            Assert.False(PowerAnswers.Has(distributor, 5, out _));
            PowerAnswers.Keep(distributor, 5, VRage.MyResourceStateEnum.NoPower);
            Assert.True(PowerAnswers.Has(distributor, 5, out var state));
            Assert.Equal(VRage.MyResourceStateEnum.NoPower, state);
            PowerAnswers.Keep(distributor, 6, VRage.MyResourceStateEnum.Ok);
            Assert.True(PowerAnswers.Has(distributor, 6, out state));
            Assert.Equal(VRage.MyResourceStateEnum.Ok, state);
            Assert.False(PowerAnswers.Has(distributor, 5, out _));
        }

        /// <summary>Out of the game (no <c>MySandboxGame.Static</c> here) a look is the game's own getter, the same answer or the same throw.</summary>
        [Fact]
        public void Without_the_game_a_look_asks_exactly_as_the_game_does()
        {
            var distributor = new Sandbox.Game.EntityComponents.MyResourceDistributorComponent("test");
            Exception direct = null, through = null;
            VRage.MyResourceStateEnum directState = default, throughState = default;
            try { directState = distributor.ResourceState; } catch (Exception e) { direct = e; }
            try { throughState = PowerReadOnce.State(distributor); } catch (Exception e) { through = e; }
            Assert.Equal(direct?.GetType(), through?.GetType());
            if (direct == null) Assert.Equal(directState, throughState);
        }
    }

    public sealed class SccTests
    {
        private sealed class V
        {
            public readonly int Id;
            public readonly List<V> Out = new List<V>();
            public readonly List<V> In = new List<V>();
            public V(int id) => Id = id;
        }

        /// <summary>A walk as the game's: breadth first, the start yielded first.</summary>
        private static void Walk(V from, List<V> into, bool inverted)
        {
            var seen = new HashSet<V> { from };
            var queue = new Queue<V>();
            queue.Enqueue(from);
            while (queue.Count > 0)
            {
                var v = queue.Dequeue();
                into.Add(v);
                foreach (var n in inverted ? v.In : v.Out)
                    if (seen.Add(n)) queue.Enqueue(n);
            }
        }

        private static bool Reachable(V a, V b)
        {
            var list = new List<V>();
            Walk(a, list, false);
            return list.Contains(b);
        }

        /// <summary>
        /// On random directed graphs, the groups each vertex joins - those whose first vertex it reaches and is reached by,
        /// as the game's pairwise <c>Reachable</c> picks them - are the same from the kept sets, asked in any order.
        /// </summary>
        [Theory]
        [InlineData(1, 40, 60)]
        [InlineData(2, 60, 150)]
        [InlineData(3, 80, 80)]
        [InlineData(4, 30, 200)]
        public void The_kept_sets_pick_the_groups_the_pairwise_walks_pick(int seed, int vertices, int edges)
        {
            var random = new Random(seed);
            var graph = Enumerable.Range(0, vertices).Select(i => new V(i)).ToList();
            for (var e = 0; e < edges; e++)
            {
                var a = graph[random.Next(vertices)];
                var b = graph[random.Next(vertices)];
                a.Out.Add(b);
                b.In.Add(a);
            }
            var firsts = Enumerable.Range(0, 12).Select(_ => graph[random.Next(vertices)]).ToList();
            var cache = new SccCache<V>((v, l) => Walk(v, l, false), (v, l) => Walk(v, l, true));
            foreach (var v in graph.OrderBy(_ => random.Next()))
            {
                var pairwise = Enumerable.Range(0, firsts.Count).Where(i => Reachable(firsts[i], v) && Reachable(v, firsts[i])).ToList();
                var set = cache.Of(v);
                var kept = Enumerable.Range(0, firsts.Count).Where(i => set.Contains(firsts[i])).ToList();
                Assert.Equal(pairwise, kept);
            }
        }
    }
}
