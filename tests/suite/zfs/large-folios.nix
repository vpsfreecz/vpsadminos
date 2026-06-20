import ../../make-test.nix (
  { pkgs }:
  let
    checker = pkgs.stdenv.mkDerivation {
      pname = "zfs-large-folio-check";
      version = "1";

      src = pkgs.writeText "zfs-large-folio-check.c" ''
        #define _GNU_SOURCE

        #include <errno.h>
        #include <fcntl.h>
        #include <inttypes.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <sys/mman.h>
        #include <sys/stat.h>
        #include <sys/types.h>
        #include <unistd.h>

        #define FILE_SIZE (64UL * 1024UL * 1024UL)
        #define WRITE_CHUNK (1024UL * 1024UL)
        #define PAGEMAP_PRESENT (1ULL << 63)
        #define PAGEMAP_PFN_MASK ((1ULL << 55) - 1)
        #define KPF_COMPOUND_HEAD 15
        #define KPF_COMPOUND_TAIL 16
        #define KPF_THP 22
        #define FNV1A_OFFSET_BASIS UINT64_C(14695981039346656037)
        #define FNV1A_PRIME UINT64_C(1099511628211)

        static unsigned char
        test_byte_at(size_t offset)
        {
          return (unsigned char)((offset % WRITE_CHUNK) * 131U + 17U);
        }

        static uint64_t
        fnv1a_byte(uint64_t checksum, unsigned char byte)
        {
          return (checksum ^ byte) * FNV1A_PRIME;
        }

        static uint64_t
        expected_data_checksum(void)
        {
          uint64_t checksum = FNV1A_OFFSET_BASIS;

          for (size_t i = 0; i < FILE_SIZE; i++)
            checksum = fnv1a_byte(checksum, test_byte_at(i));

          return checksum;
        }

        static uint64_t
        mapped_data_checksum(const unsigned char *data, size_t len)
        {
          uint64_t checksum = FNV1A_OFFSET_BASIS;

          for (size_t i = 0; i < len; i++)
            checksum = fnv1a_byte(checksum, data[i]);

          return checksum;
        }

        static int
        read_exact_at(int fd, void *buf, size_t len, off_t off)
        {
          char *p = buf;

          while (len > 0) {
            ssize_t ret = pread(fd, p, len, off);

            if (ret < 0) {
              if (errno == EINTR)
                continue;
              return -1;
            }

            if (ret == 0) {
              errno = EIO;
              return -1;
            }

            p += ret;
            off += ret;
            len -= (size_t)ret;
          }

          return 0;
        }

        static int
        write_all(int fd, const void *buf, size_t len)
        {
          const char *p = buf;

          while (len > 0) {
            ssize_t ret = write(fd, p, len);

            if (ret < 0) {
              if (errno == EINTR)
                continue;
              return -1;
            }

            p += ret;
            len -= (size_t)ret;
          }

          return 0;
        }

        static int
        write_test_file(const char *path)
        {
          unsigned char *buf = malloc(WRITE_CHUNK);
          int fd;

          if (buf == NULL)
            return -1;

          for (size_t i = 0; i < WRITE_CHUNK; i++)
            buf[i] = test_byte_at(i);

          fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
          if (fd < 0) {
            free(buf);
            return -1;
          }

          for (size_t off = 0; off < FILE_SIZE; off += WRITE_CHUNK) {
            if (write_all(fd, buf, WRITE_CHUNK) != 0) {
              close(fd);
              free(buf);
              return -1;
            }
          }

          free(buf);

          if (fsync(fd) != 0) {
            close(fd);
            return -1;
          }

          (void)posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);

          if (close(fd) != 0)
            return -1;

          return 0;
        }

        int
        main(int argc, char **argv)
        {
          const char *path;
          long page_size;
          size_t pages;
          int fd = -1;
          int pagemap = -1;
          int kpageflags = -1;
          unsigned char *map = MAP_FAILED;
          uint64_t checksum;
          uint64_t expected_checksum;
          size_t present = 0;
          size_t with_pfn = 0;
          size_t compound_head = 0;
          size_t compound_tail = 0;
          size_t thp = 0;

          setvbuf(stdout, NULL, _IONBF, 0);

          if (argc != 2) {
            fprintf(stderr, "usage: %s PATH\n", argv[0]);
            return 2;
          }

          path = argv[1];
          page_size = sysconf(_SC_PAGESIZE);
          if (page_size <= 0) {
            perror("sysconf(_SC_PAGESIZE)");
            return 1;
          }

          if (write_test_file(path) != 0) {
            perror("write_test_file");
            return 1;
          }

          fd = open(path, O_RDONLY);
          if (fd < 0) {
            perror("open test file");
            return 1;
          }

          (void)posix_fadvise(fd, 0, FILE_SIZE, POSIX_FADV_DONTNEED);
          (void)posix_fadvise(fd, 0, FILE_SIZE, POSIX_FADV_SEQUENTIAL);

          map = mmap(NULL, FILE_SIZE, PROT_READ, MAP_SHARED, fd, 0);
          if (map == MAP_FAILED) {
            perror("mmap");
            close(fd);
            return 1;
          }

          if (madvise(map, FILE_SIZE, MADV_HUGEPAGE) != 0) {
            perror("madvise MADV_HUGEPAGE");
            munmap(map, FILE_SIZE);
            close(fd);
            return 1;
          }

          (void)madvise(map, FILE_SIZE, MADV_SEQUENTIAL);

          pages = FILE_SIZE / (size_t)page_size;
          checksum = mapped_data_checksum(map, FILE_SIZE);
          expected_checksum = expected_data_checksum();

          pagemap = open("/proc/self/pagemap", O_RDONLY);
          if (pagemap < 0) {
            perror("open /proc/self/pagemap");
            munmap(map, FILE_SIZE);
            close(fd);
            return 1;
          }

          kpageflags = open("/proc/kpageflags", O_RDONLY);
          if (kpageflags < 0) {
            perror("open /proc/kpageflags");
            close(pagemap);
            munmap(map, FILE_SIZE);
            close(fd);
            return 1;
          }

          for (size_t i = 0; i < pages; i++) {
            uintptr_t vaddr = (uintptr_t)(map + i * (size_t)page_size);
            uint64_t entry;
            uint64_t pfn;
            uint64_t flags;
            off_t pagemap_off = (off_t)((vaddr / (uintptr_t)page_size) * 8);

            if (read_exact_at(pagemap, &entry, sizeof(entry), pagemap_off) != 0) {
              perror("read pagemap");
              return 1;
            }

            if ((entry & PAGEMAP_PRESENT) == 0)
              continue;

            present++;
            pfn = entry & PAGEMAP_PFN_MASK;
            if (pfn == 0)
              continue;

            with_pfn++;

            if (read_exact_at(kpageflags, &flags, sizeof(flags),
                (off_t)(pfn * 8)) != 0) {
              perror("read kpageflags");
              return 1;
            }

            if ((flags & (1ULL << KPF_COMPOUND_HEAD)) != 0)
              compound_head++;

            if ((flags & (1ULL << KPF_COMPOUND_TAIL)) != 0)
              compound_tail++;

            if ((flags & (1ULL << KPF_THP)) != 0)
              thp++;
          }

          printf("LARGE_FOLIO_PRESENT_PAGES=%zu\n", present);
          printf("LARGE_FOLIO_PFN_VISIBLE_PAGES=%zu\n", with_pfn);
          printf("LARGE_FOLIO_COMPOUND_HEAD_PAGES=%zu\n", compound_head);
          printf("LARGE_FOLIO_COMPOUND_TAIL_PAGES=%zu\n", compound_tail);
          printf("LARGE_FOLIO_THP_PAGES=%zu\n", thp);
          printf("LARGE_FOLIO_CHECKSUM=%016" PRIx64 "\n", checksum);
          printf("LARGE_FOLIO_EXPECTED_CHECKSUM=%016" PRIx64 "\n",
              expected_checksum);

          if (checksum != expected_checksum) {
            fprintf(stderr,
                "mapped payload checksum mismatch: got %016" PRIx64
                ", expected %016" PRIx64 "\n",
                checksum, expected_checksum);
            return 1;
          }

          printf("LARGE_FOLIO_CHECKSUM_MATCH=1\n");

          if (present == 0 || with_pfn == 0) {
            fprintf(stderr, "no present pages with visible PFNs in pagemap\n");
            return 1;
          }

          if (compound_tail == 0) {
            fprintf(stderr, "no compound tail pages found for ZFS mapping\n");
            return 1;
          }

          printf("LARGE_FOLIO_RESULT=ok\n");

          close(kpageflags);
          close(pagemap);
          munmap(map, FILE_SIZE);
          close(fd);

          return 0;
        }
      '';

      dontUnpack = true;

      buildPhase = ''
        runHook preBuild
        $CC -O2 -Wall -Wextra -o zfs-large-folio-check "$src"
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin"
        cp zfs-large-folio-check "$out/bin/"
        runHook postInstall
      '';
    };
  in
  {
    name = "zfs-large-folios";

    description = ''
      Verify that ZFS advertises and actually receives large page-cache folios.
    '';

    tags = [
      "ci"
      "regression"
    ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool("tank", timeout: 45 * 60)

      machine.push_file("${checker}/bin/zfs-large-folio-check", "/tmp/zfs-large-folio-check")
      machine.succeeds("chmod +x /tmp/zfs-large-folio-check")

      machine.succeeds("zfs destroy -r tank/large-folio-test >/dev/null 2>&1 || true")
      machine.succeeds("zfs create -o mountpoint=/large-folio-test tank/large-folio-test")

      begin
        _, output = machine.succeeds("/tmp/zfs-large-folio-check /large-folio-test/check.bin", timeout: 300)
        expect(output).to include("LARGE_FOLIO_CHECKSUM_MATCH=1")
        expect(output).to include("LARGE_FOLIO_RESULT=ok")
      ensure
        machine.execute("zfs destroy -r tank/large-folio-test >/dev/null 2>&1")
      end
    '';
  }
)
