package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test
import sun.misc.Unsafe
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.player.ExperimentalMedia3Output
import xyz.luan.audioplayers.player.PlayerWrapper
import xyz.luan.audioplayers.player.WrappedPlayer
import xyz.luan.audioplayers.source.Source

/** Exercises actual setting entry points without creating an Android audio output. */
class Media3RetirementSettingsTest {
    private class Output : PlayerWrapper, ExperimentalMedia3Output {
        override fun getDuration():Int?=null; override fun getCurrentPosition():Int?=null; override fun isLiveStream()=false
        override fun start(){}; override fun pause(){}; override fun stop(){}; override fun seekTo(position:Int){}
        override fun setVolume(leftVolume:Float,rightVolume:Float){ fail("setting reached retired Media3") }
        override fun setRate(rate:Float){}; override fun setLooping(looping:Boolean){}; override fun updateContext(context:AudioContextAndroid){}
        override fun setSource(source:Source){}; override fun prepare(){}; override fun release(){}; override fun reset(){}
    }
    private fun player():WrappedPlayer {
        val field=Unsafe::class.java.getDeclaredField("theUnsafe"); field.isAccessible=true
        val instance=(field.get(null) as Unsafe).allocateInstance(WrappedPlayer::class.java) as WrappedPlayer
        val player=WrappedPlayer::class.java.getDeclaredField("player"); player.isAccessible=true; player.set(instance,Output())
        return instance
    }
    @Test fun equalizerChangeRequestsRetirementAndRetainsLatestSettings() {
        val p=player(); var retires=0; p.onMedia3RetireRequested={retires++}
        p.setEqualizer(mapOf("enabled" to true,"preamp" to 3)); assertEquals(1,retires)
        p.setEqualizer(mapOf("enabled" to false)); assertEquals(1,retires)
        val field=WrappedPlayer::class.java.getDeclaredField("pendingMedia3Equalizer"); field.isAccessible=true
        assertEquals(false,(field.get(p) as Map<*,*>)["enabled"])
    }
    @Test fun balanceChangeRequestsRetirementAndRetainsFinalValue() {
        val p=player(); var retires=0; p.onMedia3RetireRequested={retires++}
        p.balance=0.4f; assertEquals(1,retires); assertEquals(0.4f,p.balance,0.001f)
        p.balance=0.2f; assertEquals(2,retires); assertEquals(0.2f,p.balance,0.001f)
    }
    @Test fun settingsAfterDeckReleaseKeepLatestValuesInEitherOrder() {
        val a=player(); a.onMedia3RetireRequested={}; a.balance=0.4f
        val output=WrappedPlayer::class.java.getDeclaredField("player"); output.isAccessible=true; output.set(a,null)
        a.setEqualizer(mapOf("enabled" to true,"preamp" to 5)); a.balance=0.2f
        val pending=WrappedPlayer::class.java.getDeclaredField("pendingMedia3Equalizer"); pending.isAccessible=true
        assertEquals(5,(pending.get(a) as Map<*,*>)["preamp"]); assertEquals(0.2f,a.balance,0.001f)
        val b=player(); b.onMedia3RetireRequested={}; b.setEqualizer(mapOf("enabled" to true,"preamp" to 1)); output.set(b,null)
        b.balance=0.3f; b.setEqualizer(mapOf("enabled" to true,"preamp" to 7))
        assertEquals(7,(pending.get(b) as Map<*,*>)["preamp"]); assertEquals(0.3f,b.balance,0.001f)
    }

}
