using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Composition;
using System.Numerics;

namespace Yingyu.Update;

// Reuse the retained DetailArtwork loader and its Image.Source. All artwork
// identity, cache priority, cancellation and generation checks remain there.
internal static class DetailPresentation
{
    static readonly ConditionalWeakTable<FrameworkElement,State> States=new();
    internal static void Apply(FrameworkElement page,DesktopThemePalette p,bool visible)=>States.GetValue(page,x=>new State(x)).Apply(p,visible);
    sealed class State
    {
        readonly FrameworkElement page;
        readonly Grid layer=new(){Name="DetailCinemaWindowLayer",IsHitTestVisible=false,Visibility=Visibility.Collapsed};
        readonly Grid banner=new(){Name="DetailCinemaBackdrop",IsHitTestVisible=false,VerticalAlignment=VerticalAlignment.Top};
        readonly Canvas bodyArtwork=new(){Name="DetailBodyArtwork",IsHitTestVisible=false};
        readonly Border fade=new(){Name="DetailCinemaFade"};
        readonly Border readability=new(){IsHitTestVisible=false};
        readonly Image picture=new(){Name="DetailCinemaImage",Stretch=Stretch.UniformToFill};
        readonly Grid titleSlice=new(){Name="DesktopUnifiedTitleSlice",Height=32,IsHitTestVisible=false,VerticalAlignment=VerticalAlignment.Top};
        readonly Canvas titleArtwork=new(){Name="DetailTitleArtwork",IsHitTestVisible=false,Height=32};
        readonly Border normalTitle=new(){VerticalAlignment=VerticalAlignment.Top};
        readonly Image titlePicture=new(){Stretch=Stretch.UniformToFill,VerticalAlignment=VerticalAlignment.Top};
        readonly Border titleFade=new(){VerticalAlignment=VerticalAlignment.Top};
        readonly Border titleSide=new(){VerticalAlignment=VerticalAlignment.Top};
        readonly Border captionShield=new(){Name="DetailCaptionShield",Height=80,VerticalAlignment=VerticalAlignment.Top,IsHitTestVisible=false};
        readonly Border captionBody=new(){Name="DetailCaptionFade",Height=80,VerticalAlignment=VerticalAlignment.Top,IsHitTestVisible=false};
        ScrollViewer? observed;
        Visual? bodyVisual,titleVisual;
        ExpressionAnimation? scrollAnimation;
        DesktopThemePalette? palette;
        bool entryPending=true;
        int entryEpoch;
        string? displayedItem;
        void ResetEntry()
        {
            var view=Access.Get<Grid>(page,"DetailView");
            if(view.Visibility!=Visibility.Visible)return;
            string? id=Access.Get<EmbyDesktop.Core.Models.EmbyItem?>(page,"_currentDetailItem")?.Id;
            if(!entryPending&&displayedItem==id)return;
            entryPending=false;displayedItem=id;int epoch=++entryEpoch;
            var scroll=Access.Get<ScrollViewer>(page,"DetailContentScrollViewer");scroll.ChangeView(null,0,null,true);
            page.DispatcherQueue.TryEnqueue(()=>{
                if(epoch==entryEpoch&&view.Visibility==Visibility.Visible&&displayedItem==Access.Get<EmbyDesktop.Core.Models.EmbyItem?>(page,"_currentDetailItem")?.Id)
                    scroll.ChangeView(null,0,null,true);
            });
        }
        void Observe(ScrollViewer? next)
        {
            if(ReferenceEquals(next,observed))return;
            foreach(var visual in new[]{bodyVisual,titleVisual})if(visual!=null){visual.StopAnimation("Translation.Y");visual.Properties.InsertVector3("Translation",Vector3.Zero);}
            scrollAnimation?.Dispose();scrollAnimation=null;observed=next;
            if(next==null)return;
            ElementCompositionPreview.SetIsTranslationEnabled(banner,true);
            ElementCompositionPreview.SetIsTranslationEnabled(titleArtwork,true);
            bodyVisual=ElementCompositionPreview.GetElementVisual(banner);
            titleVisual=ElementCompositionPreview.GetElementVisual(titleArtwork);
            scrollAnimation=bodyVisual.Compositor.CreateExpressionAnimation("scroll.Translation.Y");
            scrollAnimation.SetReferenceParameter("scroll",ElementCompositionPreview.GetScrollViewerManipulationPropertySet(next));
            bodyVisual.StartAnimation("Translation.Y",scrollAnimation);
            titleVisual.StartAnimation("Translation.Y",scrollAnimation);
        }
        void Chrome(bool detail)
        {
            if(Access.Get<Grid>(page,"ShellGrid") is not {} shell)return;
            if(shell.Children.OfType<Border>().FirstOrDefault(b=>b.Name=="DesktopAccountToolbar") is not {} bar)return;
            Grid.SetRowSpan(bar,detail?Math.Max(1,shell.RowDefinitions.Count):1);bar.VerticalAlignment=detail?VerticalAlignment.Top:VerticalAlignment.Stretch;
            if(detail){shell.RowDefinitions[0].Height=new(0);bar.Background=null;}
        }

        public State(FrameworkElement page)
        {
            this.page=page;
            Access.Get<Grid>(page,"DetailView").RegisterPropertyChangedCallback(UIElement.VisibilityProperty,(_,_)=>{
                if(Access.Get<Grid>(page,"DetailView").Visibility!=Visibility.Visible){entryPending=true;entryEpoch++;displayedItem=null;}
            });
            banner.Children.Add(bodyArtwork);bodyArtwork.Children.Add(picture);bodyArtwork.Children.Add(readability);bodyArtwork.Children.Add(fade);layer.Children.Add(banner);layer.Children.Add(captionBody);
            titleSlice.Children.Add(normalTitle);titleSlice.Children.Add(titleArtwork);titleArtwork.Children.Add(titlePicture);titleArtwork.Children.Add(titleSide);titleArtwork.Children.Add(titleFade);titleSlice.Children.Add(captionShield);
            page.Unloaded+=(_,_)=>{Observe(null);Chrome(false);(layer.Parent as Panel)?.Children.Remove(layer);(titleSlice.Parent as Panel)?.Children.Remove(titleSlice);picture.ClearValue(Image.SourceProperty);titlePicture.ClearValue(Image.SourceProperty);layer.Visibility=Visibility.Collapsed;};
        }
        internal void Apply(DesktopThemePalette p,bool visible)
        {
            var view=Access.Get<Grid>(page,"DetailView");
            Grid? root=null;for(DependencyObject? n=page;n!=null;n=VisualTreeHelper.GetParent(n))if(n is Grid grid&&grid.Name=="WindowRoot")root=grid;
            if(root==null)return;
            foreach(var title in UiElements.Descendants(root).OfType<Grid>().Where(g=>g.Name=="DesktopNativeTitleRegion")){
                title.Background=DesktopVisuals.Brush(0);if(!title.Children.Contains(titleSlice)){title.Children.Insert(0,titleSlice);Grid.SetColumnSpan(titleSlice,2);Canvas.SetZIndex(titleSlice,-1);titlePicture.SetBinding(Image.SourceProperty,new Binding{Source=Access.Get<Image>(page,"DetailBackdropImage"),Path=new("Source"),Mode=BindingMode.OneWay});}
            }
            Chrome(visible);titleArtwork.Width=root.ActualWidth;captionShield.Width=captionBody.Width=root.ActualWidth;
            layer.Clip=new RectangleGeometry{Rect=new Windows.Foundation.Rect(0,0,root.ActualWidth,root.ActualHeight)};
            titleSlice.Visibility=Visibility.Visible;titleSlice.Clip=new RectangleGeometry{Rect=new Windows.Foundation.Rect(0,0,root.ActualWidth,32)};
            normalTitle.Width=root.ActualWidth;normalTitle.Height=root.ActualHeight;normalTitle.Background=visible?DesktopVisuals.Brush(p.Background):root.Background;
            normalTitle.Visibility=Visibility.Visible;captionShield.Visibility=captionBody.Visibility=visible?Visibility.Visible:Visibility.Collapsed;titlePicture.Visibility=titleSide.Visibility=titleFade.Visibility=visible?Visibility.Visible:Visibility.Collapsed;
            if(!visible){Observe(null);layer.Visibility=Visibility.Collapsed;return;}
            ResetEntry();
            Observe(Access.Get<ScrollViewer>(page,"DetailContentScrollViewer"));
            if(!root.Children.Contains(layer)){
                picture.SetBinding(Image.SourceProperty,new Binding{Source=Access.Get<Image>(page,"DetailBackdropImage"),Path=new("Source"),Mode=BindingMode.OneWay});
                root.Children.Insert(0,layer);Grid.SetRowSpan(layer,Math.Max(1,root.RowDefinitions.Count));Grid.SetColumnSpan(layer,Math.Max(1,root.ColumnDefinitions.Count));Canvas.SetZIndex(layer,-1);
            }
            layer.Visibility=Visibility.Visible;layer.Background=DesktopVisuals.Brush(p.Background);
            double height=Math.Clamp(page.ActualWidth*.43,440,720);banner.Width=root.ActualWidth;banner.Height=height;
            picture.Width=bodyArtwork.Width=readability.Width=fade.Width=root.ActualWidth;picture.Height=bodyArtwork.Height=readability.Height=fade.Height=height;
            banner.Clip=new RectangleGeometry{Rect=new Windows.Foundation.Rect(0,0,root.ActualWidth,height)};
            titlePicture.Width=root.ActualWidth;titlePicture.Height=height;titleFade.Width=titleSide.Width=root.ActualWidth;titleFade.Height=titleSide.Height=height;
            if(palette!=p)
            {
                palette=p;
                var caption=new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(0,1)};
                uint captionTint=p.Background&0x00FFFFFF;
                foreach(var stop in new (double Offset,uint Alpha)[]{(0,0xB0),(.20,ReferenceSurfaces.Dark(page)?0xA8u:0x90u),(.55,0x30),(1,0)})caption.GradientStops.Add(new(){Offset=stop.Offset,Color=DesktopMaterial.Color((stop.Alpha<<24)|captionTint)});captionShield.Background=captionBody.Background=caption;
                var gradient=new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(0,1)};
                uint tint=p.Background&0x00FFFFFF;
                foreach(var stop in new (double Offset,uint Alpha)[]{(0,0x10),(.32,0x20),(.52,0x58),(.70,0xB0),(.86,0xEC),(1,0xFF)})gradient.GradientStops.Add(new(){Offset=stop.Offset,Color=DesktopMaterial.Color((stop.Alpha<<24)|tint)});
                fade.Background=gradient;
                var side=new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(1,0)};
                side.GradientStops.Add(new(){Offset=0,Color=DesktopMaterial.Color(0xC0000000|tint)});side.GradientStops.Add(new(){Offset=.45,Color=DesktopMaterial.Color(0x68000000|tint)});side.GradientStops.Add(new(){Offset=1,Color=DesktopMaterial.Color(tint)});readability.Background=side;
                titleFade.Background=gradient;titleSide.Background=side;
            }
            // The last gradient stop and the content background use exactly the
            // same opaque color, so the photograph has no rectangular bottom edge.
            view.Background=DesktopVisuals.Brush(0);
            var layout=Access.Get<Grid>(page,"DetailPageLayout");double inset=Math.Clamp(page.ActualWidth*.04,24,74);
            var padding=new Thickness(inset,height*.38+64,inset,46);if(layout.Padding!=padding)layout.Padding=padding;
        }
    }
}
