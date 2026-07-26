CREATE TABLE IF NOT EXISTS "EmailJob" (
  "id" TEXT PRIMARY KEY,
  "kind" TEXT NOT NULL,
  "recipient" TEXT NOT NULL,
  "payload" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'pending',
  "attempts" INTEGER NOT NULL DEFAULT 0,
  "scheduledAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "lockedAt" TIMESTAMP(3),
  "lastError" TEXT,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "EmailJob_status_scheduledAt_createdAt_idx"
  ON "EmailJob"("status", "scheduledAt", "createdAt");
CREATE INDEX IF NOT EXISTS "EmailJob_lockedAt_idx" ON "EmailJob"("lockedAt");

CREATE TABLE IF NOT EXISTS "LoginRateLimit" (
  "key" TEXT PRIMARY KEY,
  "scope" TEXT NOT NULL,
  "identifierHash" TEXT NOT NULL,
  "count" INTEGER NOT NULL DEFAULT 0,
  "windowStartedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "blockedUntil" TIMESTAMP(3),
  "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "LoginRateLimit_blockedUntil_idx" ON "LoginRateLimit"("blockedUntil");
CREATE INDEX IF NOT EXISTS "LoginRateLimit_updatedAt_idx" ON "LoginRateLimit"("updatedAt");
