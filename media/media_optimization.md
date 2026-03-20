Feed & Paging tập trung vào logic điều hướng dữ liệu (Data Orchestration), trong khi Media Optimization lại thuộc về trải nghiệm người dùng (UX) và tối ưu hóa hạ tầng (Infrastructure)


1. Phía Server-side & Infra
- CDN (Content Delivery Network): Giải thích tại sao phải đẩy image ra edge (gần user nhất).
- Dynamic Resizing: Thay vì lưu 10 size khác nhau, sử dụng các service như Cloudinary hoặc tự dựng (với Libvips/Sharp) để resize ảnh on-the-fly qua URL: image.com/post_1/width=400&format=webp.
- Modern Formats: Ưu tiên WebP hoặc AVIF thay vì JPEG/PNG để giảm 30-50% dung lượng mà chất lượng không đổi.

2. Phía Client-side (Trải nghiệm "Mượt")
- BlurHash / ThumbHash: Thay vì để một khung trắng xóa khi ảnh chưa load xong, chúng ta hiển thị một mảng màu được mã hóa từ ảnh gốc (chỉ mất ~30 bytes). User sẽ có cảm giác ảnh đang "hiện hình" dần dần.
- Lazy Loading & Intersection Observer: Chỉ load ảnh khi user cuộn đến gần vị trí đó.
- Image Pre-fetching: Dựa vào tốc độ cuộn của user để "đoán" và load trước 1-2 ảnh tiếp theo.

3. Progressive Image Loading
- Cơ chế hiển thị ảnh từ độ phân giải thấp (thấp hơn cả BlurHash) lên độ phân giải cao để tránh hiện tượng giật (jank) khung hình khi ảnh nhảy vào.