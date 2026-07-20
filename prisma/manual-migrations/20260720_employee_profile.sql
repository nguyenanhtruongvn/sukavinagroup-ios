ALTER TABLE "Employee"
  ADD COLUMN IF NOT EXISTS "managerEmployeeCode" TEXT,
  ADD COLUMN IF NOT EXISTS "hireDate" TIMESTAMP(3),
  ADD COLUMN IF NOT EXISTS "contractType" TEXT;

ALTER TABLE "EmployeeRequest"
  ADD COLUMN IF NOT EXISTS "managerEmployeeId" TEXT,
  ADD COLUMN IF NOT EXISTS "managerEmployeeCode" TEXT,
  ADD COLUMN IF NOT EXISTS "decisionNote" TEXT,
  ADD COLUMN IF NOT EXISTS "decidedAt" TIMESTAMP(3),
  ADD COLUMN IF NOT EXISTS "dueAt" TIMESTAMP(3),
  ADD COLUMN IF NOT EXISTS "autoApproved" BOOLEAN NOT NULL DEFAULT false;

UPDATE "EmployeeRequest" SET "dueAt" = "createdAt" + INTERVAL '4 hours' WHERE "dueAt" IS NULL;
ALTER TABLE "EmployeeRequest" ALTER COLUMN "dueAt" SET NOT NULL;

CREATE TABLE IF NOT EXISTS "UserNotification" (
  "id" TEXT PRIMARY KEY,
  "recipientId" TEXT NOT NULL,
  "type" TEXT NOT NULL,
  "title" TEXT NOT NULL,
  "message" TEXT NOT NULL,
  "requestId" TEXT,
  "read" BOOLEAN NOT NULL DEFAULT false,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS "UserNotification_recipientId_createdAt_idx" ON "UserNotification"("recipientId", "createdAt");
CREATE INDEX IF NOT EXISTS "UserNotification_recipientId_read_idx" ON "UserNotification"("recipientId", "read");
