CC = gcc
CFLAGS = -static -Wall -Wextra -Werror
RM = rm -rf

TARGET = sysinfo
SOURCE = $(TARGET).c

.PHONY: all clean

all: $(TARGET)

clean:
	$(RM) $(TARGET)

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) -o $@ $(SOURCE)
