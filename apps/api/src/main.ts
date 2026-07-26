import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import cluster from 'cluster';
import { availableParallelism } from 'os';
import { AppModule } from './app/app.module';
import { AllExceptionsFilter } from './logging/all-exceptions.filter';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  const allowedOrigins = new Set(
    (process.env.CORS_ORIGINS ?? 'https://sukavinagroup.net')
      .split(',')
      .map((origin) => origin.trim())
      .filter(Boolean),
  );
  if (process.env.NODE_ENV !== 'production') {
    allowedOrigins.add('http://localhost:4200');
    allowedOrigins.add('http://localhost:5173');
  }
  app.enableCors({
    origin: (origin, callback) => {
      if (!origin || allowedOrigins.has(origin)) return callback(null, true);
      callback(new Error('Origin is not allowed by CORS'));
    },
    credentials: true,
  });
  app.useGlobalFilters(app.get(AllExceptionsFilter));
  const globalPrefix = 'api';
  app.setGlobalPrefix(globalPrefix);
  const port = process.env.PORT || 3000;
  await app.listen(port);
  Logger.log(
    `Application listening on port ${port} with prefix /${globalPrefix}`,
  );
}

const requestedWorkers = Number(process.env.API_WORKERS ?? 2);
const workerCount = Number.isFinite(requestedWorkers)
  ? Math.max(1, Math.min(Math.floor(requestedWorkers), availableParallelism()))
  : 2;

if (cluster.isPrimary && workerCount > 1) {
  Logger.log(`Starting ${workerCount} API workers`);
  for (let index = 0; index < workerCount; index += 1) cluster.fork();
  cluster.on('exit', (worker, code) => {
    Logger.error(
      `API worker ${worker.process.pid} exited with code ${code}; restarting`,
    );
    cluster.fork();
  });
} else {
  void bootstrap();
}
