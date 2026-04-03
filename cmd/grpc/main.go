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
	db, err := database.ConnectDB()
	if err != nil {
		log.Fatalf("DB 연결 실패: %v", err)
	}
	orderRepo := repository.NewOrderRepo(db)

	grpcServerLogic := mygrpc.NewOrderGrpcServer(orderRepo)

	s := grpc.NewServer()
	pb.RegisterOrderServiceServer(s, grpcServerLogic)
	reflection.Register(s)

	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("포트 50051 리슨 실패: %v", err)
	}

	if err := s.Serve(lis); err != nil {
		log.Fatalf("gRPC 서버 실행 실패: %v", err)
	}
}
