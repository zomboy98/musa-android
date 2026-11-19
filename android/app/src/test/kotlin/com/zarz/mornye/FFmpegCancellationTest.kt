package com.zarz.mornye

import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class FFmpegCancellationTest {
    @Test fun absentThenLateCallbackDoesNotPretendProducerStopped() {
        val latch = CountDownLatch(1)
        try {
            awaitFFmpegCancellation(latch, 1)
            fail("expected unconfirmed termination")
        } catch (_: FFmpegProducerUnconfirmed) {
            assertEquals(1L, latch.count)
        }
        latch.countDown()
        try {
            awaitFFmpegCancellation(latch, 1)
            fail("expected cancellation")
        } catch (error: CancellationException) {
            assertFalse(error is FFmpegProducerUnconfirmed)
        }
    }

    @Test fun conversionAttemptsUseDistinctStageNames() {
        val first = NativeDownloadFinalizer.stagedConversionPath("/tmp/song.flac")
        val second = NativeDownloadFinalizer.stagedConversionPath("/tmp/song.flac")
        assertNotEquals(first, second)
        assertTrue(first.endsWith(".partial.flac"))
    }

    @Test fun deadlineCancelsOnceAndLateCompletionDoesNotConfirmBeforeCallback() {
        var now = 0L
        var cancels = 0
        var callback = false
        val waits = mutableListOf<Long>()
        try {
            awaitFFmpegOperation(
                waitForCompletion = { milliseconds ->
                    waits.add(milliseconds)
                    now += TimeUnit.MILLISECONDS.toNanos(milliseconds)
                    callback
                },
                nowNanos = { now },
                shouldCancel = { false },
                cancel = { cancels++ },
                timeoutNanos = TimeUnit.MILLISECONDS.toNanos(400),
                pollMs = 200,
                acknowledgementMs = 10,
            )
            fail("expected unconfirmed termination")
        } catch (_: FFmpegProducerUnconfirmed) {
            assertEquals(1, cancels)
            assertEquals(listOf(200L, 200L, 10L), waits)
            assertFalse(callback)
        }
        // A callback after the caller timed out is a separate event.
        callback = true
        awaitFFmpegOperation(
            waitForCompletion = { callback },
            nowNanos = { now },
            shouldCancel = { false },
            cancel = { cancels++ },
            timeoutNanos = 1,
        )
        assertEquals(1, cancels)
    }

    @Test fun terminalNotificationsRemainIndependentAndExactlyOnce() {
        val events = mutableListOf<String>()
        val first = FFmpegTerminalNotifier({ events.add("first stopped") }, { events.add("first not started") })
        val second = FFmpegTerminalNotifier({ events.add("second stopped") }, { events.add("second not started") })
        // No notification is delivered merely because a caller times out or closes.
        assertTrue(events.isEmpty())
        second.notStarted()
        first.stopped() // the real callback can arrive after the caller returned
        first.stopped()
        second.stopped()
        assertEquals(listOf("second not started", "first stopped"), events)
    }

    @Test fun optionalValidationDeadlineIsAFailureWithAcknowledgedOrUnconfirmedStop() {
        for (acknowledged in listOf(false, true)) {
            var now = 0L
            var cancels = 0
            try {
                awaitFFmpegOperation(
                    waitForCompletion = { milliseconds ->
                        now += TimeUnit.MILLISECONDS.toNanos(milliseconds)
                        cancels > 0 && acknowledged
                    },
                    nowNanos = { now },
                    shouldCancel = { false },
                    cancel = { cancels++ },
                    timeoutNanos = TimeUnit.MILLISECONDS.toNanos(1),
                    timeoutAsFailure = true,
                )
                fail("expected timeout")
            } catch (error: FFmpegOperationTimeout) {
                assertEquals(acknowledged, error.terminationConfirmed)
                assertEquals(1, cancels)
            }
        }
    }

    @Test fun explicitCancellationWinsWhenItArrivesDuringTimeoutAcknowledgement() {
        var now = 0L
        var cancelled = false
        try {
            awaitFFmpegOperation(
                waitForCompletion = { milliseconds ->
                    now += TimeUnit.MILLISECONDS.toNanos(milliseconds)
                    cancelled
                },
                nowNanos = { now },
                shouldCancel = { cancelled },
                cancel = { cancelled = true },
                timeoutNanos = 1L,
                timeoutAsFailure = true,
            )
            fail("expected cancellation")
        } catch (error: CancellationException) {
            assertFalse(error is FFmpegProducerUnconfirmed)
        }
    }

    @Test fun failedAcknowledgementDoesNotPreventTerminalCallbackReturning() {
        val notifier = FFmpegTerminalNotifier({ throw IllegalStateException("bridge closed") }, null)
        notifier.stopped()
        notifier.stopped()
    }

    @Test fun activeCancellationWithoutCallbackIsDistinctFromConfirmedStop() {
        var cancels = 0
        try {
            awaitFFmpegOperation(
                waitForCompletion = { false },
                nowNanos = { 0 },
                shouldCancel = { true },
                cancel = { cancels++ },
                timeoutNanos = 1,
                timeoutAsFailure = true,
            )
            fail("expected unconfirmed cancellation")
        } catch (_: FFmpegProducerUnconfirmed) {
            assertEquals(1, cancels)
        }
    }
}
