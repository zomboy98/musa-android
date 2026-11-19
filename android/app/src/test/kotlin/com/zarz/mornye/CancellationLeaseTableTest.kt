package com.zarz.mornye
import org.junit.Assert.*
import org.junit.Test
class CancellationLeaseTableTest {
    @Test fun cancelKeepsLeaseAliveWithoutBlockingOtherIds() {
        val table = CancellationLeaseTable<Any>()
        val first = Any(); val other = Any()
        table.add("first", first)
        assertTrue(table.beginCancel("first"))
        assertTrue(table.remove("first", first).isEmpty())
        table.add("other", other)
        assertEquals(listOf(other), table.remove("other", other))
        assertEquals(listOf(first), table.endCancel("first"))
        assertFalse(table.beginCancel("first"))
    }
    @Test fun overlappingCancelsDelayReleaseUntilLastEnds() {
        val table = CancellationLeaseTable<Any>(); val lease = Any()
        table.add("id", lease)
        assertTrue(table.beginCancel("id")); assertTrue(table.beginCancel("id"))
        assertTrue(table.remove("id", lease).isEmpty())
        assertTrue(table.endCancel("id").isEmpty())
        assertEquals(listOf(lease), table.endCancel("id"))
        assertTrue(table.remove("id", lease).isEmpty())
    }
    @Test fun blockedNativeCancelDoesNotBlockOtherIdsOrCloseTheLeaseEarly() {
        val table = CancellationLeaseTable<Any>(); val lease = Any()
        table.add("slow", lease)
        val entered = java.util.concurrent.CountDownLatch(1)
        val finish = java.util.concurrent.CountDownLatch(1)
        val pool = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val cancel = pool.submit<List<Any>> {
                check(table.beginCancel("slow")); entered.countDown()
                check(finish.await(5, java.util.concurrent.TimeUnit.SECONDS))
                table.endCancel("slow")
            }
            assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            val other = pool.submit<Boolean> {
                val item = Any(); table.add("other", item)
                table.remove("other", item) == listOf(item) && table.remove("slow", lease).isEmpty()
            }
            assertTrue(other.get(1, java.util.concurrent.TimeUnit.SECONDS))
            finish.countDown()
            assertEquals(listOf(lease), cancel.get(5, java.util.concurrent.TimeUnit.SECONDS))
        } finally { finish.countDown(); pool.shutdownNow() }
    }
}
