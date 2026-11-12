using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using HarmonyLib;
using Sandbox;
using Sandbox.Engine.Multiplayer;
using Sandbox.Engine.Voxels;
using Sandbox.Game.Entities;

namespace SentisClientOptimisation
{
    /// <summary>
    /// An asteroid or a planet the server takes from the client no longer freezes the client while its voxels are kept.
    ///
    /// When the server takes a voxel map from a client (it left the client's range, the player respawned far away), the
    /// client keeps the map's data in its cache, lest it be downloaded again when it comes back
    /// (<c>MyVoxelReplicable.OnDestroyClientInternal</c>: <c>Storage.Save</c> - every changed leaf of the map written
    /// and compressed - then <c>VoxelMapData.Write</c>). All of it on the game thread: 3.3 s of one frame for a much
    /// mined map in a trace of a player's client (11.11.2026).
    ///
    /// Now the data are made on a worker thread and put into the cache on the game thread when ready; the rest is as
    /// the game does it (an asteroid the client was given closed at once - its storage, pinned, closes when the data
    /// are made). The storage's own save takes its locks, so the game reads it meanwhile as before. The old data of the
    /// map are taken out of the cache at once: if the server gives the map again before the new are ready and counts on
    /// the client's cache, the client finds none and asks the server for the map (the game's own path for a missing
    /// cache) - never the old data. New data made late, after the map came again, are not put in.
    /// </summary>
    internal static class VoxelCacheSave
    {
        /// <summary>Maps saved on a worker thread, their data put into the cache, dropped as the map came again meanwhile.</summary>
        public static long Saved, Written, Dropped;

        private static PropertyInfo _voxel;

        /// <summary>A map's turn, by its storage name: one more each time it is taken or given (game thread).</summary>
        private static readonly Dictionary<string, int> Turns = new Dictionary<string, int>();

        public static void Patch(Harmony harmony)
        {
            const BindingFlags instance = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
            var type = typeof(MyVoxelBase).Assembly.GetType("Sandbox.Game.Replication.MyVoxelReplicable", true);
            _voxel = type.GetProperty("Voxel", instance) ?? throw new MissingMemberException(type.Name, "Voxel");
            var destroy = type.GetMethod("OnDestroyClientInternal", instance, null, Type.EmptyTypes, null)
                          ?? throw new MissingMethodException(type.Name, "OnDestroyClientInternal");
            var load = type.GetMethods(instance).FirstOrDefault(m => m.Name == "OnLoad" && m.DeclaringType == type)
                       ?? throw new MissingMethodException(type.Name, "OnLoad");
            harmony.Patch(destroy, prefix: new HarmonyMethod(typeof(VoxelCacheSave), nameof(DestroyPrefix)));
            harmony.Patch(load, postfix: new HarmonyMethod(typeof(VoxelCacheSave), nameof(LoadPostfix)));
        }

        private static int Next(string name)
        {
            Turns.TryGetValue(name, out var turn);
            Turns[name] = ++turn;
            return turn;
        }

        /// <summary>The game's taking of the map, its data made on a worker thread.</summary>
        private static bool DestroyPrefix(object __instance)
        {
            MyVoxelBase voxel;
            try
            {
                voxel = (MyVoxelBase)_voxel.GetValue(__instance);
            }
            catch (Exception e)
            {
                Plugin.Log("a voxel map taken: " + e);
                return true;
            }
            if (voxel == null) return false;
            var multiplayer = MyMultiplayer.Static;
            if (voxel.Storage is MyStorageBase storage && multiplayer != null && voxel.StorageName != null)
            {
                var name = voxel.StorageName;
                var turn = Next(name);
                multiplayer.VoxelMapData.Remove(name);
                var pin = storage.Pin();
                if (pin.Valid)
                {
                    Saved++;
                    Background.Run(() =>
                    {
                        byte[] data = null;
                        try
                        {
                            storage.Save(out data);
                        }
                        catch (Exception e)
                        {
                            Plugin.Log("saving the voxel map " + name + ": " + e);
                        }
                        finally
                        {
                            pin.Dispose();
                        }
                        if (data == null) return;
                        MySandboxGame.Static?.Invoke(() =>
                        {
                            if (MyMultiplayer.Static == multiplayer && Turns.TryGetValue(name, out var now) && now == turn)
                            {
                                multiplayer.VoxelMapData.Write(name, data);
                                Written++;
                            }
                            else Dropped++;
                        }, Plugin.Id + " voxel cache");
                    });
                }
                else pin.Dispose();
            }
            if (voxel.Save && !(voxel is MyPlanet)) voxel.Close();
            return false;
        }

        /// <summary>A map given by <see cref="VoxelLoadAsync"/>: as <see cref="LoadPostfix"/>.</summary>
        public static void Given(MyVoxelBase voxel)
        {
            var name = voxel?.StorageName;
            if (name != null && Turns.ContainsKey(name)) Next(name);
        }

        /// <summary>The map given again: data of its last taking still being made are not put in.</summary>
        private static void LoadPostfix(object __instance)
        {
            try
            {
                var name = ((MyVoxelBase)_voxel.GetValue(__instance))?.StorageName;
                if (name != null && Turns.ContainsKey(name)) Next(name);
            }
            catch (Exception)
            {
            }
        }
    }
}
