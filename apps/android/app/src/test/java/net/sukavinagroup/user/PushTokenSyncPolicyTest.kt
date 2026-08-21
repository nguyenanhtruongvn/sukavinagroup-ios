package net.sukavinagroup.user

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushTokenSyncPolicyTest {
    @Test
    fun acceptsFirebaseTokenWithinApiLimit() {
        assertTrue(PushTokenSyncPolicy.isValidToken("fcm-token"))
        assertTrue(PushTokenSyncPolicy.isValidToken("x".repeat(4096)))
        assertFalse(PushTokenSyncPolicy.isValidToken(null))
        assertFalse(PushTokenSyncPolicy.isValidToken(""))
        assertFalse(PushTokenSyncPolicy.isValidToken("x".repeat(4097)))
    }

    @Test
    fun retriesOnlyFailuresThatCanRecoverWithoutUserAction() {
        assertTrue(PushTokenSyncPolicy.shouldRetry(null))
        assertTrue(PushTokenSyncPolicy.shouldRetry(429))
        assertTrue(PushTokenSyncPolicy.shouldRetry(503))
        assertFalse(PushTokenSyncPolicy.shouldRetry(400))
        assertFalse(PushTokenSyncPolicy.shouldRetry(401))
        assertFalse(PushTokenSyncPolicy.shouldRetry(403))
    }
}
