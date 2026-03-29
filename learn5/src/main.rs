use aws_sdk_s3::{
    config::{Credentials, Region},
    primitives::ByteStream,
    Client,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let endpoint = std::env::var("MINIO_ENDPOINT")
        .unwrap_or_else(|_| "http://minio.minio.svc:9000".to_string());
    let access_key = std::env::var("AWS_ACCESS_KEY_ID")
        .unwrap_or_else(|_| "minioadmin".to_string());
    let secret_key = std::env::var("AWS_SECRET_ACCESS_KEY")
        .unwrap_or_else(|_| "minioadmin".to_string());
    let bucket = std::env::var("BUCKET_NAME")
        .unwrap_or_else(|_| "rust-bucket".to_string());

    let credentials = Credentials::new(&access_key, &secret_key, None, None, "env");

    let config = aws_sdk_s3::Config::builder()
        .behavior_version(aws_config::BehaviorVersion::latest())
        .credentials_provider(credentials)
        // aws-sdk-s3 はリージョン指定が必須のため設定しているが、
        // endpoint_url で MinIO に向けているため AWS への通信は発生しない
        .region(Region::new("us-east-1"))
        // AWS の本番 S3 ではなく MinIO のエンドポイントに向ける
        // これにより AWS アカウントや AWS への通信は一切不要
        .endpoint_url(&endpoint)
        // AWS S3 はデフォルトでバーチャルホスト形式 (bucket.s3.amazonaws.com) を使うが、
        // MinIO はパス形式 (host/bucket) を使うため強制的に切り替える
        .force_path_style(true)
        .build();

    let client = Client::from_conf(config);

    // バケット作成
    println!("バケットを作成中: {}", bucket);
    client.create_bucket().bucket(&bucket).send().await?;
    println!("完了");

    // オブジェクトのアップロード
    let content = "Hello from Rust on Kubernetes!";
    println!("アップロード中: hello.txt");
    client
        .put_object()
        .bucket(&bucket)
        .key("hello.txt")
        .body(ByteStream::from_static(content.as_bytes()))
        .send()
        .await?;
    println!("完了");

    // オブジェクトの一覧取得
    println!("オブジェクト一覧:");
    let list = client.list_objects_v2().bucket(&bucket).send().await?;
    for obj in list.contents() {
        println!(
            "  - {} ({} bytes)",
            obj.key().unwrap_or(""),
            obj.size().unwrap_or(0)
        );
    }

    // オブジェクトのダウンロード
    println!("ダウンロード中: hello.txt");
    let get_result = client
        .get_object()
        .bucket(&bucket)
        .key("hello.txt")
        .send()
        .await?;
    let data = get_result.body.collect().await?;
    let downloaded = String::from_utf8(data.into_bytes().to_vec())?;
    println!("内容: {}", downloaded);

    Ok(())
}
