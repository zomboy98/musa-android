package com.zarz.mornye

import java.util.concurrent.CompletableFuture
import org.junit.Assert.*
import org.junit.Test

class SessionWorkOperationTest {
    @Test fun onlyCompletedSuccessfulOperationReturnsTrue() {
        assertTrue(awaitSessionWorkOperation(CompletableFuture.completedFuture(Unit), 50))
        val failed = CompletableFuture<Unit>(); failed.completeExceptionally(IllegalStateException("fixture"))
        assertFalse(awaitSessionWorkOperation(failed, 50))
        assertFalse(awaitSessionWorkOperation(CompletableFuture<Unit>(), 1))
    }
    @Test fun interruptionIsPreserved() {
        val thread = Thread.currentThread()
        thread.interrupt()
        try { assertFalse(awaitSessionWorkOperation(CompletableFuture<Unit>(), 50)); assertTrue(thread.isInterrupted) }
        finally { Thread.interrupted() }
    }
    @Test fun enqueueFailureIsReportedUnlessWorkWasStopped() {
        assertTrue(reportSessionRescheduleFailure(false, false))
        assertFalse(reportSessionRescheduleFailure(false, true))
        assertFalse(reportSessionRescheduleFailure(true, false))
    }
}
