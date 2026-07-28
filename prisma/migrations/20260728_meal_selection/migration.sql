CREATE TABLE "MealSelection" (
    "id" TEXT NOT NULL,
    "employeeId" TEXT NOT NULL,
    "mealDate" TIMESTAMP(3) NOT NULL,
    "choice" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    CONSTRAINT "MealSelection_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "MealSelection_employeeId_mealDate_key"
ON "MealSelection"("employeeId", "mealDate");

CREATE INDEX "MealSelection_mealDate_idx" ON "MealSelection"("mealDate");

ALTER TABLE "MealSelection"
ADD CONSTRAINT "MealSelection_employeeId_fkey"
FOREIGN KEY ("employeeId") REFERENCES "Employee"("id")
ON DELETE CASCADE ON UPDATE CASCADE;
