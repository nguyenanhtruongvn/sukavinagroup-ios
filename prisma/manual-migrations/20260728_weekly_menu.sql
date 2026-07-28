CREATE TABLE IF NOT EXISTS "WeeklyMenu" (
  "id" TEXT NOT NULL,
  "weekStart" TIMESTAMP(3) NOT NULL,
  "data" JSONB NOT NULL,
  "sourceName" TEXT NOT NULL,
  "importedBy" TEXT NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "WeeklyMenu_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "WeeklyMenu_weekStart_key"
  ON "WeeklyMenu"("weekStart");

CREATE INDEX IF NOT EXISTS "WeeklyMenu_weekStart_idx"
  ON "WeeklyMenu"("weekStart");
