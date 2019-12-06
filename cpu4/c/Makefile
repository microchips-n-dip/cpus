all: cpu4

cpu4: cpu4.o reservation_station.o
	gcc build/cpu4.o build/reservation_station.o -o cpu4

cpu4.o: build
	gcc -c cpu4.c -o build/cpu4.o

reservation_station.o: build
	gcc -c reservation_station.c -o build/reservation_station.o

build:
	mkdir build

clean:
	rm build/*.o
	rm cpu4

