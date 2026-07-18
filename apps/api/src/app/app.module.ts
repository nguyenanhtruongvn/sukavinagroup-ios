import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { AdminModule } from '../admin/admin.module';
import { EmployeesModule } from '../employees/employees.module';
import { DashboardModule } from '../dashboard/dashboard.module';
import { LogsModule } from '../logs/logs.module';
import { RequestLoggingMiddleware } from '../logging/request-logging.middleware';
import { AllExceptionsFilter } from '../logging/all-exceptions.filter';
import { SeedModule } from '../seeds/seed.module';
import { AccountsModule } from '../accounts/accounts.module';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { MediaModule } from '../media/media.module';

@Module({
  imports: [
    AuthModule,
    DashboardModule,
    AdminModule,
    EmployeesModule,
    LogsModule,
    AccountsModule,
    MediaModule,
    SeedModule,
  ],
  controllers: [AppController],
  providers: [AppService, RequestLoggingMiddleware, AllExceptionsFilter],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    consumer.apply(RequestLoggingMiddleware).forRoutes('*');
  }
}
