import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { PassportModule } from '@nestjs/passport';
import { PrismaService } from '../prisma/prisma.service';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { JwtStrategy } from './jwt.strategy';
import { RegistrationEventsService } from './registration-events.service';
import { MailService } from './mail.service';

@Module({
  imports: [
    PassportModule,
    JwtModule.register({
      secret: process.env.JWT_SECRET ?? 'dev-secret',
      signOptions: { expiresIn: '8h' },
    }),
  ],
  controllers: [AuthController],
  providers: [
    AuthService,
    PrismaService,
    JwtStrategy,
    RegistrationEventsService,
    MailService,
  ],
  exports: [
    AuthService,
    JwtModule,
    PassportModule,
    PrismaService,
    RegistrationEventsService,
    MailService,
  ],
})
export class AuthModule {}
