import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
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
  Logger.log(`Application listening on port ${port} with prefix /${globalPrefix}`);
}

bootstrap();
