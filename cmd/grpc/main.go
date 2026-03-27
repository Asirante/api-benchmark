package main

import (
	"log"
	"net"

	"api-benchmark/internal/adapter/database"
	mygrpc "api-benchmark/internal/adapter/grpc"
	"api-benchmark/internal/adapter/grpc/pb"
	"api-benchmark/internal/core/repository"

	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

func main() {
	log.Println("🛠️ gRPC API 서버 초기화 중...")

	// 1. DB 연결 및 레포지토리 생성
	db, err := database.ConnectDB()
	if err != nil {
		log.Fatalf("❌ DB 연결 실패: %v", err)
	}
	orderRepo := repository.NewOrderRepo(db)

	// 2. 우리가 만든 gRPC 로직 객체 생성
	grpcServerLogic := mygrpc.NewOrderGrpcServer(orderRepo)

	// 3. 순수 gRPC 서버 뼈대 생성
	s := grpc.NewServer()

	// 4. 자동 생성된 코드에 우리의 비즈니스 로직을 등록!
	pb.RegisterOrderServiceServer(s, grpcServerLogic)

	// 5. 리플렉션 활성화 (포스트맨이나 grpcurl 도구로 테스트하기 위해 필수)
	reflection.Register(s)

	// 6. 50051 포트 열기
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("❌ 포트 50051 리슨 실패: %v", err)
	}

	log.Println("🚀 gRPC 서버가 포트 50051에서 실행되었습니다!")
	if err := s.Serve(lis); err != nil {
		log.Fatalf("❌ gRPC 서버 실행 실패: %v", err)
	}
}
